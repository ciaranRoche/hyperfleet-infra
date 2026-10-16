#!/usr/bin/env python3
"""Stand-in for the OCI-side node provisioner of a platform None hosted cluster.

It plays the service that, in production, the cloud provider would run: it
reads node pool intent from the HyperFleet API and launches, replaces, drains
and terminates RHCOS instances in the customer's compartment, then does the
guest-side steps a None cluster needs (CSR approval, node labels and taints,
the OCI provider package, ingress DNS). See README.md for the contract and the
list of shortcuts, each of which is a seam a real provisioner has to solve.

Standard library only; shells out to `oci`, `kubectl` and `openssl`.
"""

import argparse
import base64
import json
import os
import random
import socket
import string
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ADAPTER = "oci-provisioner"
TAG_NODEPOOL = "hyperfleet-nodepool-id"
TAG_CLUSTER = "hyperfleet-cluster"
TAG_CONFIG = "hyperfleet-config-version"
BOOTSTRAPPER = "system:serviceaccount:openshift-machine-config-operator:node-bootstrapper"


def log(msg):
    print(f"[{time.strftime('%H:%M:%S', time.gmtime())}] {msg}", flush=True)


def run(args, check=True, env=None, input_text=None):
    proc = subprocess.run(args, capture_output=True, text=True, env=env, input=input_text)
    if check and proc.returncode != 0:
        raise RuntimeError(f"{' '.join(args[:4])}...: {(proc.stderr or proc.stdout).strip()[:400]}")
    return proc.stdout


class Config:
    def __init__(self):
        self.api = os.environ.get("HYPERFLEET_API", "http://127.0.0.1:18000/api/hyperfleet/v1")
        self.mgmt_kubeconfig = os.environ["MGMT_KUBECONFIG"]
        self.clusters_namespace = os.environ.get("CLUSTERS_NAMESPACE", "clusters")
        self.dns_zone = os.environ.get("DNS_ZONE", "oci.hypershell.app")
        self.dns_compartment = os.environ.get("DNS_COMPARTMENT_ID", "")
        self.repo_root = os.environ.get("REPO_ROOT", os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))
        self.owner = os.environ.get("OWNER_TAG", os.environ.get("USER", "unknown"))
        self.workdir = os.environ.get("WORKDIR", os.path.expanduser("~/.cache/oci-poc-provisioner"))
        os.makedirs(self.workdir, mode=0o700, exist_ok=True)


# --------------------------------------------------------------------------
# HyperFleet API
# --------------------------------------------------------------------------
class HyperFleet:
    def __init__(self, base):
        self.base = base

    def call(self, method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method,
                                     headers={"Content-Type": "application/json"})
        for attempt in range(5):
            try:
                with urllib.request.urlopen(req, timeout=20) as resp:
                    raw = resp.read()
                    return json.loads(raw) if raw else {}
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    return None
                raise RuntimeError(f"{method} {path}: HTTP {e.code} {e.read()[:300]!r}")
            except (urllib.error.URLError, ConnectionError, TimeoutError):
                time.sleep(3 * (attempt + 1))
        raise RuntimeError(f"{method} {path}: API unreachable")

    def items(self, path):
        out = self.call("GET", path) or {}
        return out.get("items", [])

    def adapter_data(self, path, adapter):
        for item in self.items(path + "/statuses"):
            if item.get("adapter") == adapter:
                return item
        return None


def condition(obj, ctype):
    for c in (obj.get("status") or {}).get("conditions", []):
        if c.get("type") == ctype:
            return c.get("status") == "True"
    return False


# --------------------------------------------------------------------------
# OCI
# --------------------------------------------------------------------------
def oci_json(args, check=True):
    out = run(["oci"] + args, check=check)
    return json.loads(out) if out.strip() else {}


def list_instances(compartment):
    data = oci_json(["compute", "instance", "list", "--compartment-id", compartment, "--all"]).get("data", [])
    return [i for i in data if i["lifecycle-state"] not in ("TERMINATED", "TERMINATING")]


def availability_domain(compartment):
    return oci_json(["iam", "availability-domain", "list", "--compartment-id", compartment])["data"][0]["name"]


# --------------------------------------------------------------------------
# Kubernetes: management cluster and guest
# --------------------------------------------------------------------------
def kube(kubeconfig, args, check=True, input_text=None):
    return run(["kubectl", "--kubeconfig", kubeconfig, "--request-timeout=30s"] + args, check=check, input_text=input_text)


class Guest:
    """Admin access to a hosted cluster through a management-cluster port-forward.

    A real provisioner would not hold guest admin credentials; needing them is
    one of the seams in README.md.
    """

    def __init__(self, cfg, name):
        self.cfg, self.name = cfg, name
        self.proc = None
        self.kubeconfig = None

    def __enter__(self):
        ns = f"{self.cfg.clusters_namespace}-{self.name}"
        secret = kube(self.cfg.mgmt_kubeconfig, ["-n", self.cfg.clusters_namespace, "get", "secret",
                                                 f"{self.name}-admin-kubeconfig", "-o", "jsonpath={.data.kubeconfig}"])
        raw = base64.b64decode(secret).decode()
        sock = socket.socket()
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
        sock.close()
        self.proc = subprocess.Popen(["kubectl", "--kubeconfig", self.cfg.mgmt_kubeconfig, "-n", ns, "port-forward",
                                      "svc/kube-apiserver", f"{port}:6443"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        lines = []
        for line in raw.splitlines():
            if line.strip().startswith("server:"):
                host = line.split("//", 1)[1].split(":", 1)[0]
                indent = line[: len(line) - len(line.lstrip())]
                lines.append(f"{indent}server: https://127.0.0.1:{port}")
                lines.append(f"{indent}tls-server-name: {host}")
            else:
                lines.append(line)
        fd, self.kubeconfig = tempfile.mkstemp(prefix=f"{self.name}-", suffix=".kubeconfig", dir=self.cfg.workdir)
        with os.fdopen(fd, "w") as f:
            f.write("\n".join(lines) + "\n")
        for _ in range(20):
            if subprocess.run(["kubectl", "--kubeconfig", self.kubeconfig, "--request-timeout=5s", "get", "--raw", "/readyz"],
                              capture_output=True).returncode == 0:
                return self
            time.sleep(1)
        raise RuntimeError(f"guest API of {self.name} not reachable through port-forward")

    def __exit__(self, *exc):
        if self.proc:
            self.proc.terminate()
        if self.kubeconfig and os.path.exists(self.kubeconfig):
            os.remove(self.kubeconfig)

    def k(self, args, check=True, input_text=None):
        last = None
        for _ in range(3):
            try:
                return kube(self.kubeconfig, args, check=check, input_text=input_text)
            except RuntimeError as e:
                last = e
                time.sleep(2)
        raise last

    def nodes(self):
        return {n["metadata"]["name"]: n for n in json.loads(self.k(["get", "nodes", "-o", "json"]))["items"]}

    def approve_csrs(self, names):
        """Approve kubelet CSRs, but only for instances this provisioner launched."""
        approved = []
        for csr in json.loads(self.k(["get", "csr", "-o", "json"]))["items"]:
            if (csr.get("status") or {}).get("conditions"):
                continue
            signer, user = csr["spec"]["signerName"], csr["spec"]["username"]
            node = None
            if signer == "kubernetes.io/kube-apiserver-client-kubelet" and user == BOOTSTRAPPER:
                pem = base64.b64decode(csr["spec"]["request"]).decode()
                subject = run(["openssl", "req", "-noout", "-subject"], input_text=pem)
                if "CN=system:node:" in subject.replace(" ", ""):
                    node = subject.replace(" ", "").split("CN=system:node:", 1)[1].split(",")[0].strip()
            elif signer == "kubernetes.io/kubelet-serving" and user.startswith("system:node:"):
                node = user[len("system:node:"):]
            if node and node in names:
                self.k(["certificate", "approve", csr["metadata"]["name"]])
                approved.append(f"{csr['metadata']['name']} ({node})")
        return approved


# --------------------------------------------------------------------------
# Provisioner
# --------------------------------------------------------------------------
class Provisioner:
    def __init__(self, cfg):
        self.cfg = cfg
        self.api = HyperFleet(cfg.api)
        self._ad = {}

    def user_data(self, namespace, name):
        """Read the ignition stub. It carries a bearer token; it is written to a
        0600 file only for the duration of a launch."""
        value = kube(self.cfg.mgmt_kubeconfig, ["-n", namespace, "get", "secret", name, "-o", "jsonpath={.data.value}"])
        fd, path = tempfile.mkstemp(prefix="user-data-", dir=self.cfg.workdir)
        with os.fdopen(fd, "wb") as f:
            f.write(base64.b64decode(value))
        return path

    def launch(self, cluster, np, status, existing):
        spec = np["spec"]
        name = f"{cluster['name']}-{np['name']}-" + "".join(random.choices(string.ascii_lowercase + string.digits, k=5))
        fds = spec.get("fault_domains") or []
        used = [i.get("fault-domain") for i in existing]
        fd = min(fds, key=lambda d: used.count(d)) if fds else None
        compartment = spec["compartment_id"]
        if compartment not in self._ad:
            self._ad[compartment] = availability_domain(compartment)
        data = status["data"]
        ud = self.user_data(data["user_data_secret_namespace"], data["user_data_secret_name"])
        try:
            args = ["compute", "instance", "launch", "--compartment-id", compartment,
                    "--availability-domain", self._ad[compartment], "--shape", spec.get("shape", "VM.Standard.E5.Flex"),
                    "--shape-config", json.dumps({"ocpus": spec.get("ocpus", 4), "memoryInGBs": spec.get("memory_gb", 16)}),
                    "--image-id", spec["image_id"], "--subnet-id", spec["subnet_id"], "--assign-public-ip", "false",
                    "--nsg-ids", json.dumps(spec.get("nsg_ids", [])), "--display-name", name, "--hostname-label", name,
                    "--boot-volume-size-in-gbs", str(spec.get("boot_volume_gb", 120)), "--user-data-file", ud,
                    "--instance-options", json.dumps({"areLegacyImdsEndpointsDisabled": True}),
                    "--freeform-tags", json.dumps({"owner": self.cfg.owner, "hyperfleet-purpose": "oci-on-oke-poc",
                                                   "hyperfleet-managed-by": ADAPTER, TAG_CLUSTER: cluster["name"],
                                                   TAG_NODEPOOL: np["id"], TAG_CONFIG: data["config_version"]})]
            if fd:
                args += ["--fault-domain", fd]
            oci_json(args)
        finally:
            os.remove(ud)
        log(f"{cluster['name']}/{np['name']}: launched {name} ({fd or 'any fault domain'}, config {data['config_version']})")

    def remove(self, guest, instance, why):
        name = instance["display-name"]
        if guest:
            guest.k(["cordon", name], check=False)
            guest.k(["drain", name, "--ignore-daemonsets", "--delete-emptydir-data", "--force", "--timeout=300s"], check=False)
            guest.k(["delete", "node", name, "--ignore-not-found"], check=False)
        oci_json(["compute", "instance", "terminate", "--instance-id", instance["id"], "--preserve-boot-volume", "false", "--force"])
        log(f"terminating {name}: {why}")

    def reconcile_nodepool(self, guest, cluster, np, instances, nodes):
        path = f"/clusters/{cluster['id']}/nodepools/{np['id']}"
        status = self.api.adapter_data(path, "np-hypershift")
        mine = [i for i in instances if i["freeform-tags"].get(TAG_NODEPOOL) == np["id"]]
        deleting = bool(np.get("deleted_time"))
        desired = 0 if deleting else int(np["spec"].get("count", 0))
        if not deleting and not (status and status["data"].get("user_data_secret_name")):
            return mine
        current = status["data"]["config_version"] if status else ""
        fresh = [i for i in mine if i["freeform-tags"].get(TAG_CONFIG) == current]
        stale = [i for i in mine if i not in fresh]
        ready = {n for n, o in nodes.items()
                 if any(c["type"] == "Ready" and c["status"] == "True" for c in o["status"]["conditions"])}

        if guest:
            approved = guest.approve_csrs({i["display-name"] for i in mine})
            if approved:
                log(f"{cluster['name']}/{np['name']}: approved {', '.join(approved)}")
            self.apply_labels_taints(guest, np, [i["display-name"] for i in mine if i["display-name"] in nodes])

        # One change per pass: scale up or surge, then retire stale, then scale down.
        if len(fresh) < desired:
            self.launch(cluster, np, status, mine)
        elif stale and all(i["display-name"] in ready for i in fresh):
            self.remove(guest, stale[0], f"config {stale[0]['freeform-tags'].get(TAG_CONFIG)} replaced by {current}")
        elif len(mine) > desired:
            victim = sorted(mine, key=lambda i: i["time-created"])[-1]
            self.remove(guest, victim, "scale down" if not deleting else "node pool deleted")

        self.report(path, np, mine, ready, desired, current)
        return mine

    def apply_labels_taints(self, guest, np, names):
        """None never applies NodePool labels or taints to nodes; the launcher does."""
        labels = np["spec"].get("labels") or {}
        taints = np["spec"].get("taints") or []
        for name in names:
            if labels:
                guest.k(["label", "node", name, "--overwrite"] + [f"{k}={v}" for k, v in labels.items()], check=False)
            for t in taints:
                guest.k(["taint", "node", name, "--overwrite", f"{t['key']}={t.get('value', '')}:{t['effect']}"], check=False)

    def report(self, path, np, mine, ready, desired, current):
        names = [i["display-name"] for i in mine]
        n_ready = len([n for n in names if n in ready])
        body = {
            "adapter": ADAPTER,
            "observed_generation": np["generation"],
            "observed_time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "conditions": [
                {"type": "Applied", "status": "True" if len(mine) == desired else "False",
                 "reason": "InstancesMatch" if len(mine) == desired else "Scaling",
                 "message": f"{len(mine)} instances for {desired} desired"},
                {"type": "Available", "status": "True" if n_ready >= desired else "False",
                 "reason": "NodesReady" if n_ready >= desired else "NodesNotReady",
                 "message": f"{n_ready} of {desired} nodes Ready"},
                {"type": "Health", "status": "True", "reason": "Healthy", "message": "ok"},
                {"type": "Finalized", "status": "True" if np.get("deleted_time") and not mine else "False",
                 "reason": "InstancesGone" if np.get("deleted_time") and not mine else "NotDeleting", "message": "-"},
            ],
            "data": {"instances": names, "ready_nodes": n_ready, "config_version": current},
        }
        try:
            self.api.call("PUT", path + "/statuses", body)
        except RuntimeError as e:
            log(f"status report refused: {e}")

    def bootstrap_guest(self, guest, cluster):
        """Provider package, ingress load balancer and *.apps DNS, once nodes exist."""
        spec = cluster.get("spec") or {}
        installed = guest.k(["get", "ns", "oci-cloud-controller-manager", "--ignore-not-found", "-o", "name"], check=False).strip()
        if not installed:
            if not all(spec.get(k) for k in ("compartment_id", "vcn_id", "lb_subnet_id")):
                log(f"{cluster['name']}: spec lacks compartment_id, vcn_id or lb_subnet_id; skipping provider package")
                return
            env = dict(os.environ, GUEST_KUBECONFIG=guest.kubeconfig, COMPARTMENT_ID=spec["compartment_id"],
                       VCN_ID=spec["vcn_id"], LB_SUBNET_ID=spec["lb_subnet_id"], CLUSTER_TAG=cluster["name"],
                       OUTDIR=os.path.join(self.cfg.workdir, f"guest-oci-{cluster['name']}"))
            script = os.path.join(self.cfg.repo_root, "scripts", "oci-poc-guest-oci.sh")
            run([script, "install"], env=env)
            log(f"{cluster['name']}: OCI provider package installed")
        if guest.k(["get", "config.imageregistry", "cluster", "-o", "jsonpath={.spec.storage.pvc.claim}"], check=False).strip() == "":
            env = dict(os.environ, GUEST_KUBECONFIG=guest.kubeconfig)
            run([os.path.join(self.cfg.repo_root, "scripts", "oci-poc-guest-oci.sh"), "configure"], env=env)
            log(f"{cluster['name']}: guest configured (masquerade subnet, ingress load balancer, registry)")
        ip = guest.k(["-n", "openshift-ingress", "get", "svc", "router-default", "-o",
                      "jsonpath={.status.loadBalancer.ingress[0].ip}"], check=False).strip()
        if ip and self.cfg.dns_compartment:
            domain = f"*.apps.{cluster['name']}.{spec.get('base_domain', 'hcp.oci.hypershell.app')}"
            have = oci_json(["dns", "record", "rrset", "get", "--zone-name-or-id", self.cfg.dns_zone, "--domain", domain,
                             "--rtype", "A", "--compartment-id", self.cfg.dns_compartment], check=False)
            if [r["rdata"] for r in (have.get("data") or {}).get("items", [])] != [ip]:
                oci_json(["dns", "record", "rrset", "update", "--zone-name-or-id", self.cfg.dns_zone, "--domain", domain,
                          "--rtype", "A", "--compartment-id", self.cfg.dns_compartment, "--force",
                          "--items", json.dumps([{"domain": domain, "rtype": "A", "rdata": ip, "ttl": 60}])])
                log(f"{cluster['name']}: {domain} -> {ip}")

    def cleanup_guest(self, guest, cluster):
        """Before a cluster's control plane goes, remove what its guest CCM and CSI
        created in the customer compartment, while they can still do it."""
        svcs = json.loads(guest.k(["get", "svc", "-A", "-o", "json"]))["items"]
        for s in svcs:
            if s["spec"].get("type") == "LoadBalancer":
                guest.k(["-n", s["metadata"]["namespace"], "delete", "svc", s["metadata"]["name"], "--wait=false"], check=False)
        guest.k(["delete", "pvc", "-A", "--all", "--wait=false"], check=False)
        log(f"{cluster['name']}: guest LoadBalancer Services and PVCs deleted")

    def reap(self, live_clusters, live_nodepools, compartments):
        """Remove anything tagged for a cluster or node pool the API no longer has."""
        for comp in compartments:
            for i in list_instances(comp):
                tags = i["freeform-tags"]
                if tags.get("hyperfleet-managed-by") == ADAPTER and tags.get(TAG_NODEPOOL) not in live_nodepools:
                    oci_json(["compute", "instance", "terminate", "--instance-id", i["id"], "--preserve-boot-volume", "false", "--force"])
                    log(f"reaped instance {i['display-name']} (node pool gone)")
            for kind, lister, deleter in (
                ("load balancer", ["lb", "load-balancer", "list"], ["lb", "load-balancer", "delete", "--load-balancer-id"]),
                ("NSG", ["network", "nsg", "list"], ["network", "nsg", "delete", "--network-security-group-id"]),
                ("volume", ["bv", "volume", "list"], ["bv", "volume", "delete", "--volume-id"]),
            ):
                for r in oci_json(lister + ["--compartment-id", comp, "--all"], check=False).get("data", []):
                    owner = (r.get("freeform-tags") or {}).get(TAG_CLUSTER)
                    state = r.get("lifecycle-state", "")
                    if owner and owner not in live_clusters and state not in ("DELETED", "DELETING", "TERMINATED", "TERMINATING"):
                        run(["oci"] + deleter + [r["id"], "--force"], check=False)
                        log(f"reaped {kind} {r.get('display-name')} (cluster {owner} gone)")

    def pass_once(self):
        clusters = self.api.items("/clusters")
        nodepools = self.api.items("/nodepools")
        live_clusters = {c["name"] for c in clusters}
        live_nodepools = {n["id"] for n in nodepools}
        compartments = set()
        for c in clusters:
            spec = c.get("spec") or {}
            if spec.get("compartment_id"):
                compartments.add(spec["compartment_id"])
            hc = self.api.adapter_data(f"/clusters/{c['id']}", "hc-hypershift")
            hc_up = hc and any(x["type"] == "Available" and x["status"] == "True" for x in hc["conditions"])
            pools = [n for n in nodepools if (n.get("owner_references") or {}).get("id") == c["id"]]
            for n in pools:
                compartments.add(n["spec"].get("compartment_id"))
            instances = []
            for comp in {n["spec"].get("compartment_id") for n in pools if n["spec"].get("compartment_id")}:
                instances += list_instances(comp)
            try:
                guest_ctx = Guest(self.cfg, c["name"]) if hc_up else None
                if guest_ctx:
                    guest_ctx.__enter__()
            except RuntimeError as e:
                log(f"{c['name']}: no guest access yet ({e})")
                guest_ctx = None
            try:
                nodes = guest_ctx.nodes() if guest_ctx else {}
                if c.get("deleted_time") and guest_ctx:
                    self.cleanup_guest(guest_ctx, c)
                for n in pools:
                    self.reconcile_nodepool(guest_ctx, c, n, instances, nodes)
                if guest_ctx and not c.get("deleted_time") and any(
                        any(x["type"] == "Ready" and x["status"] == "True" for x in o["status"]["conditions"])
                        for o in nodes.values()):
                    self.bootstrap_guest(guest_ctx, c)
            finally:
                if guest_ctx:
                    guest_ctx.__exit__(None, None, None)
        compartments.discard(None)
        compartments |= set(filter(None, os.environ.get("REAP_COMPARTMENTS", "").split(",")))
        self.reap(live_clusters, live_nodepools, compartments)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--once", action="store_true", help="run one reconcile pass and exit")
    parser.add_argument("--interval", type=int, default=30, help="seconds between passes")
    args = parser.parse_args()
    cfg = Config()
    prov = Provisioner(cfg)
    while True:
        try:
            prov.pass_once()
        except Exception as e:  # keep the loop alive; a pass is idempotent
            log(f"pass failed: {e}")
        if args.once:
            return
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())

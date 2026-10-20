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
import calendar
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
# On a volume whose guest PV has reclaim policy Retain: kept when the cluster goes.
TAG_RETAIN = "hyperfleet-retain"
MANAGED_ANNOTATION = "hyperfleet.io/oci-provisioner-managed"
GONE = ("DELETED", "DELETING", "TERMINATED", "TERMINATING")
# Repair: a node NotReady this long, or an instance running this long without
# ever registering a node, is replaced.
NOT_READY_GRACE = 300
NEVER_JOINED_GRACE = 900
# How long a cluster delete keeps its nodes while the guest removes its load
# balancers and volumes; after that the reaper takes over.
GUEST_CLEANUP_GRACE = 600
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


def age_seconds(stamp):
    return time.time() - calendar.timegm(time.strptime(stamp[:19], "%Y-%m-%dT%H:%M:%S"))


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
        self.blocked = {}    # node pool id -> why a drain is paused
        self.cordoned = {}   # node pool id -> the node left cordoned by that drain
        self.retained = set()  # volume OCIDs already tagged TAG_RETAIN
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

    def unhealthy(self, mine, nodes, have_guest):
        """Instances to repair, with the reason: stopped in OCI, a node NotReady
        past the grace period, or running past the join grace with no node."""
        out = {}
        for i in mine:
            name, state = i["display-name"], i["lifecycle-state"]
            if state in ("STOPPED", "STOPPING"):
                out[i["id"]] = f"instance {state}"
            elif not have_guest or state != "RUNNING":
                continue
            elif name in nodes:
                c = next((c for c in nodes[name]["status"]["conditions"] if c["type"] == "Ready"), None)
                if c and c["status"] != "True" and age_seconds(c["lastTransitionTime"]) > NOT_READY_GRACE:
                    out[i["id"]] = f"node Ready={c['status']} since {c['lastTransitionTime']}"
            elif age_seconds(i["time-created"]) > NEVER_JOINED_GRACE:
                out[i["id"]] = "no node after 15 minutes"
        return out

    def remove(self, guest, instance, why, drain=True):
        """Cordon, drain, delete the Node, terminate. A drain that cannot finish
        (a PodDisruptionBudget, say) pauses instead: the node stays cordoned and
        the instance running, the node pool reports why, the next pass retries."""
        name, pool = instance["display-name"], instance["freeform-tags"].get(TAG_NODEPOOL)
        if guest:
            guest.k(["cordon", name], check=False)
            if drain:
                try:
                    kube(guest.kubeconfig, ["drain", name, "--ignore-daemonsets", "--delete-emptydir-data", "--force", "--timeout=60s"])
                except RuntimeError as e:
                    reason = self.drain_blocker(guest, name) or str(e)[-160:]
                    if pool not in self.blocked:
                        log(f"drain of {name} paused ({why}): {reason}")
                    self.blocked[pool] = f"drain of {name} paused: {reason}"
                    self.cordoned[pool] = name
                    return False
            guest.k(["delete", "node", name, "--ignore-not-found"], check=False)
        self.blocked.pop(pool, None)
        self.cordoned.pop(pool, None)
        oci_json(["compute", "instance", "terminate", "--instance-id", instance["id"], "--preserve-boot-volume", "false", "--force"])
        log(f"terminating {name}: {why}")

    def drain_blocker(self, guest, node):
        """Name the pods a drain could not evict and the budgets holding them."""
        pods = json.loads(guest.k(["get", "pods", "-A", "--field-selector", f"spec.nodeName={node}", "-o", "json"], check=False) or '{"items": []}')["items"]
        left = [p for p in pods if p["status"].get("phase") not in ("Succeeded", "Failed")
                and not any(o.get("kind") in ("DaemonSet", "Node") for o in p["metadata"].get("ownerReferences", []))]
        if not left:
            return ""
        pdbs = json.loads(guest.k(["get", "pdb", "-A", "-o", "json"], check=False) or '{"items": []}')["items"]
        held = []
        for b in pdbs:
            sel = (b["spec"].get("selector") or {}).get("matchLabels") or {}
            if b.get("status", {}).get("disruptionsAllowed", 1) == 0 and sel and any(
                    p["metadata"]["namespace"] == b["metadata"]["namespace"]
                    and all((p["metadata"].get("labels") or {}).get(k) == v for k, v in sel.items()) for p in left):
                held.append(f"{b['metadata']['namespace']}/{b['metadata']['name']}")
        names = ", ".join(f"{p['metadata']['namespace']}/{p['metadata']['name']}" for p in left[:5])
        return f"PodDisruptionBudget {', '.join(held)} allows no disruption ({names} not evicted)" if held else f"{names} not evicted"

    def reconcile_nodepool(self, guest, cluster, np, instances, nodes, hold=False):
        path = f"/clusters/{cluster['id']}/nodepools/{np['id']}"
        status = self.api.adapter_data(path, "np-hypershift")
        mine = [i for i in instances if i["freeform-tags"].get(TAG_NODEPOOL) == np["id"]]
        deleting = bool(np.get("deleted_time"))
        desired = 0 if deleting else int(np["spec"].get("count", 0))
        if not deleting and not (status and status["data"].get("user_data_secret_name")):
            return mine
        current = status["data"]["config_version"] if status else ""
        ready = {n for n, o in nodes.items()
                 if any(c["type"] == "Ready" and c["status"] == "True" for c in o["status"]["conditions"])}
        unhealthy = {} if deleting else self.unhealthy(mine, nodes, bool(guest))
        fresh = [i for i in mine if i["freeform-tags"].get(TAG_CONFIG) == current and i["id"] not in unhealthy]
        stale = [i for i in mine if i not in fresh]

        if guest:
            approved = guest.approve_csrs({i["display-name"] for i in mine})
            if approved:
                log(f"{cluster['name']}/{np['name']}: approved {', '.join(approved)}")
            self.apply_labels_taints(guest, np, [i["display-name"] for i in mine if i["display-name"] in nodes], nodes)

        # A paused drain is retried by whichever branch below still wants the
        # node gone; remove() pauses it again if the budget still holds.
        self.blocked.pop(np["id"], None)

        # One change per pass. A replace surges by one: launch only while the
        # pool is at or under its count, retire a stale instance once every
        # fresh one is Ready. Scale down only touches fresh instances when no
        # stale ones are left, so it never undoes a surge.
        if deleting:
            if mine and not hold:
                self.remove(guest, sorted(mine, key=lambda i: i["time-created"])[-1], "node pool deleted")
        elif len(fresh) < desired and len(mine) <= desired:
            self.launch(cluster, np, status, mine)
        elif stale and all(i["display-name"] in ready for i in fresh):
            old = stale[0]
            if old["id"] in unhealthy:
                self.remove(guest, old, f"unhealthy ({unhealthy[old['id']]}), replaced", drain=False)
            else:
                self.remove(guest, old, f"config {old['freeform-tags'].get(TAG_CONFIG)} replaced by {current}")
        elif not stale and len(mine) > desired:
            self.remove(guest, sorted(mine, key=lambda i: i["time-created"])[-1], "scale down")

        # The spec moved on while a drain was paused (count raised again, say):
        # nothing wants that node gone any more, so put it back in service.
        if guest and np["id"] not in self.blocked and np["id"] in self.cordoned:
            name = self.cordoned.pop(np["id"])
            if any(i["display-name"] == name for i in mine):
                guest.k(["uncordon", name], check=False)
                log(f"{cluster['name']}/{np['name']}: drain of {name} no longer needed, uncordoned")

        self.report(path, np, mine, ready, desired, current)
        return mine

    def apply_labels_taints(self, guest, np, names, nodes):
        """None never applies NodePool labels or taints to nodes; the launcher does.
        The keys it applied are kept in a node annotation, so a label or taint
        removed from the spec is removed from the nodes too."""
        labels = np["spec"].get("labels") or {}
        taints = np["spec"].get("taints") or []
        want_taints = {f"{t['key']}:{t['effect']}" for t in taints}
        for name in names:
            meta = nodes[name]["metadata"]
            had = json.loads((meta.get("annotations") or {}).get(MANAGED_ANNOTATION, "{}"))
            have_labels = meta.get("labels") or {}
            have_taints = {f"{t['key']}:{t['effect']}": t.get("value", "") for t in nodes[name]["spec"].get("taints") or []}
            args = [f"{k}-" for k in had.get("labels", []) if k not in labels and k in have_labels]
            args += [f"{k}={v}" for k, v in labels.items() if have_labels.get(k) != v]
            if args:
                guest.k(["label", "node", name, "--overwrite"] + args, check=False)
            for key in had.get("taints", []):
                if key not in want_taints and key in have_taints:
                    guest.k(["taint", "node", name, f"{key}-"], check=False)
            for t in taints:
                if have_taints.get(f"{t['key']}:{t['effect']}") != t.get("value", ""):
                    guest.k(["taint", "node", name, "--overwrite", f"{t['key']}={t.get('value', '')}:{t['effect']}"], check=False)
            managed = json.dumps({"labels": sorted(labels), "taints": sorted(want_taints)}, separators=(",", ":"))
            if (meta.get("annotations") or {}).get(MANAGED_ANNOTATION) != managed:
                guest.k(["annotate", "node", name, "--overwrite", f"{MANAGED_ANNOTATION}={managed}"], check=False)

    def report(self, path, np, mine, ready, desired, current):
        names = [i["display-name"] for i in mine]
        n_ready = len([n for n in names if n in ready])
        # Ready nodes on an old config do not count: while a replace is rolling,
        # this generation is not reached yet.
        stale = len([i for i in mine if i["freeform-tags"].get(TAG_CONFIG) != current])
        body = {
            "adapter": ADAPTER,
            "observed_generation": np["generation"],
            "observed_time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "conditions": [
                {"type": "Applied", "status": "True" if len(mine) == desired and np["id"] not in self.blocked else "False",
                 "reason": "DrainBlocked" if np["id"] in self.blocked else ("InstancesMatch" if len(mine) == desired else "Scaling"),
                 "message": self.blocked.get(np["id"], f"{len(mine)} instances for {desired} desired")},
                # A paused drain means this generation is not reached: say so in
                # Available, the condition the API's Reconciled is built from.
                {"type": "Available", "status": "True" if n_ready >= desired and not stale and np["id"] not in self.blocked else "False",
                 "reason": "DrainBlocked" if np["id"] in self.blocked else ("NodesNotReady" if n_ready < desired else ("Updating" if stale else "NodesReady")),
                 "message": self.blocked.get(np["id"], f"{n_ready} of {desired} nodes Ready" + (f", {stale} on an old config" if stale else ""))},
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
        # check=True: a dropped guest connection must not read as "not installed".
        installed = guest.k(["get", "ns", "oci-cloud-controller-manager", "--ignore-not-found", "-o", "name"]).strip()
        if not installed:
            if not all(spec.get(k) for k in ("compartment_id", "vcn_id", "lb_subnet_id")):
                log(f"{cluster['name']}: spec lacks compartment_id, vcn_id or lb_subnet_id; skipping provider package")
                return False
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
            return True
        return False

    def cleanup_guest(self, guest, cluster):
        """Before a cluster's control plane goes, remove what its guest CCM and CSI
        created in the customer compartment, while they can still do it. Returns
        how many load balancer Services and volumes are still there."""
        svcs = [s for s in json.loads(guest.k(["get", "svc", "-A", "-o", "json"]))["items"]
                if s["spec"].get("type") == "LoadBalancer"]
        pvs = [v for v in json.loads(guest.k(["get", "pv", "-o", "json"]))["items"]
               if v["spec"].get("persistentVolumeReclaimPolicy") != "Retain"]
        for s in svcs:
            guest.k(["-n", s["metadata"]["namespace"], "delete", "svc", s["metadata"]["name"], "--wait=false"], check=False)
        if svcs or pvs:
            guest.k(["delete", "pvc", "-A", "--all", "--wait=false"], check=False)
            log(f"{cluster['name']}: waiting on {len(svcs)} guest LoadBalancer Services and {len(pvs)} volumes")
        return len(svcs) + len(pvs)

    def mark_retained(self, guest):
        """Tag the OCI volume behind every Retain block volume PV, while the guest
        can still say which ones they are, so the reaper leaves them."""
        for pv in json.loads(guest.k(["get", "pv", "-o", "json"]))["items"]:
            csi = pv["spec"].get("csi") or {}
            vol = csi.get("volumeHandle", "")
            if pv["spec"].get("persistentVolumeReclaimPolicy") != "Retain" or csi.get("driver") != "blockvolume.csi.oraclecloud.com" \
                    or not vol.startswith("ocid1.volume.") or vol in self.retained:
                continue
            tags = oci_json(["bv", "volume", "get", "--volume-id", vol])["data"].get("freeform-tags") or {}
            if not tags.get(TAG_RETAIN):
                oci_json(["bv", "volume", "update", "--volume-id", vol, "--force",
                          "--freeform-tags", json.dumps(dict(tags, **{TAG_RETAIN: "true"}))])
                log(f"volume {pv['metadata']['name']} has reclaim policy Retain: tagged {TAG_RETAIN}")
            self.retained.add(vol)

    def remove_apps_dns(self, cluster):
        """The *.apps record is the stand-in's own; nothing else removes it."""
        if not self.cfg.dns_compartment:
            return
        domain = f"*.apps.{cluster['name']}.{(cluster.get('spec') or {}).get('base_domain', 'hcp.oci.hypershell.app')}"
        have = oci_json(["dns", "record", "rrset", "get", "--zone-name-or-id", self.cfg.dns_zone, "--domain", domain,
                         "--rtype", "A", "--compartment-id", self.cfg.dns_compartment], check=False)
        if (have.get("data") or {}).get("items"):
            oci_json(["dns", "record", "rrset", "delete", "--zone-name-or-id", self.cfg.dns_zone, "--domain", domain,
                      "--rtype", "A", "--compartment-id", self.cfg.dns_compartment, "--force"])
            log(f"{cluster['name']}: {domain} removed")

    def leftovers(self, name, compartments):
        """What the cluster still has in OCI: its instances, and the load balancers
        and volumes its guest tagged. Untagged guest resources are invisible here."""
        left = []
        for comp in compartments:
            left += [f"instance {i['display-name']}" for i in list_instances(comp)
                     if i["freeform-tags"].get(TAG_CLUSTER) == name]
            for kind, lister in (("load balancer", ["lb", "load-balancer", "list"]), ("volume", ["bv", "volume", "list"])):
                left += [f"{kind} {r.get('display-name')}"
                         for r in oci_json(lister + ["--compartment-id", comp, "--all"], check=False).get("data", [])
                         if (r.get("freeform-tags") or {}).get(TAG_CLUSTER) == name and r.get("lifecycle-state") not in GONE
                         and not (r.get("freeform-tags") or {}).get(TAG_RETAIN)]
        return left

    def report_cluster(self, cluster, ready, left):
        deleting = bool(cluster.get("deleted_time"))
        finalized = deleting and not left
        body = {
            "adapter": ADAPTER,
            "observed_generation": cluster["generation"],
            "observed_time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "conditions": [
                {"type": "Applied", "status": "True", "reason": "Observed", "message": "-"},
                {"type": "Available", "status": "True" if ready else "False",
                 "reason": "GuestBootstrapped" if ready else "GuestNotBootstrapped",
                 "message": "provider package, ingress load balancer and *.apps DNS in place" if ready else "waiting for nodes or the guest"},
                {"type": "Health", "status": "True", "reason": "Healthy", "message": "ok"},
                {"type": "Finalized", "status": "True" if finalized else "False",
                 "reason": "CloudResourcesGone" if finalized else ("CloudResourcesRemain" if deleting else "NotDeleting"),
                 "message": ", ".join(left)[:500] if left else "-"},
            ],
            "data": {"leftovers": left},
        }
        try:
            self.api.call("PUT", f"/clusters/{cluster['id']}/statuses", body)
        except RuntimeError as e:
            log(f"cluster status report refused: {e}")

    def reap(self, live_clusters, live_nodepools, compartments):
        """Remove anything tagged for a cluster or node pool the API no longer has."""
        for comp in compartments:
            for i in list_instances(comp):
                tags = i["freeform-tags"]
                if tags.get("hyperfleet-managed-by") == ADAPTER and tags.get(TAG_NODEPOOL) not in live_nodepools:
                    oci_json(["compute", "instance", "terminate", "--instance-id", i["id"], "--preserve-boot-volume", "false", "--force"])
                    log(f"reaped instance {i['display-name']} (node pool gone)")
            gone = GONE
            lbs =oci_json(["lb", "load-balancer", "list", "--compartment-id", comp, "--all"], check=False).get("data", [])
            for kind, items, deleter in (
                ("load balancer", lbs, ["lb", "load-balancer", "delete", "--load-balancer-id"]),
                ("volume", oci_json(["bv", "volume", "list", "--compartment-id", comp, "--all"], check=False).get("data", []),
                 ["bv", "volume", "delete", "--volume-id"]),
            ):
                for r in items:
                    owner = (r.get("freeform-tags") or {}).get(TAG_CLUSTER)
                    if owner and owner not in live_clusters and r.get("lifecycle-state", "") not in gone \
                            and not (r.get("freeform-tags") or {}).get(TAG_RETAIN):
                        run(["oci"] + deleter + [r["id"], "--force"], check=False)
                        log(f"reaped {kind} {r.get('display-name')} (cluster {owner} gone)")
            # The CCM tags its per-load-balancer NSGs with CreatedBy and ServiceUid
            # only, never the config tags; it names them <ns>/<svc>/<lb name>/nsg.
            live_lbs = {lb["display-name"] for lb in lbs if lb.get("lifecycle-state", "") not in gone}
            for nsg in oci_json(["network", "nsg", "list", "--compartment-id", comp, "--all"], check=False).get("data", []):
                parts = nsg.get("display-name", "").split("/")
                if (nsg.get("freeform-tags") or {}).get("CreatedBy") == "CCM" and len(parts) == 4 \
                        and parts[2] not in live_lbs and nsg.get("lifecycle-state", "") not in gone:
                    run(["oci", "network", "nsg", "delete", "--nsg-id", nsg["id"], "--force"], check=False)
                    log(f"reaped NSG {nsg['display-name']} (load balancer gone)")

    def pass_once(self):
        clusters = self.api.items("/clusters")
        nodepools = self.api.items("/nodepools")
        live_nodepools = {n["id"] for n in nodepools}
        # A deleting cluster stays live for the reaper while it has instances,
        # since its guest may still be removing its own load balancers and volumes.
        live_clusters = set()
        compartments = set()
        reports = []
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
            if not c.get("deleted_time") or any(i["freeform-tags"].get(TAG_CLUSTER) == c["name"] for i in instances):
                live_clusters.add(c["name"])
            try:
                guest_ctx = Guest(self.cfg, c["name"]) if hc_up else None
                if guest_ctx:
                    guest_ctx.__enter__()
            except RuntimeError as e:
                log(f"{c['name']}: no guest access yet ({e})")
                guest_ctx = None
            try:
                nodes = guest_ctx.nodes() if guest_ctx else {}
                hold, ready = False, False
                if c.get("deleted_time"):
                    # Keep the nodes, and with them the guest CCM and CSI, until the
                    # guest has removed its load balancers and volumes. Today this
                    # rarely gets a chance: hc-hypershift deletes the HostedCluster on
                    # the same event and the guest API is gone within a minute, so
                    # the reaper does the work. See README.md, seams.
                    if guest_ctx and nodes and self.cleanup_guest(guest_ctx, c):
                        hold = age_seconds(c["deleted_time"]) < GUEST_CLEANUP_GRACE
                    self.remove_apps_dns(c)
                for n in pools:
                    self.reconcile_nodepool(guest_ctx, c, n, instances, nodes, hold)
                if guest_ctx and not c.get("deleted_time") and any(
                        any(x["type"] == "Ready" and x["status"] == "True" for x in o["status"]["conditions"])
                        for o in nodes.values()):
                    ready = self.bootstrap_guest(guest_ctx, c)
                    self.mark_retained(guest_ctx)
                reports.append((c, ready))
            except Exception as e:  # one cluster's failure must not stop the others
                log(f"{c['name']}: pass failed for this cluster: {e}")
            finally:
                if guest_ctx:
                    guest_ctx.__exit__(None, None, None)
        compartments.discard(None)
        compartments |= set(filter(None, os.environ.get("REAP_COMPARTMENTS", "").split(",")))
        self.reap(live_clusters, live_nodepools, compartments)
        for c, ready in reports:
            self.report_cluster(c, ready, self.leftovers(c["name"], compartments) if c.get("deleted_time") else [])


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

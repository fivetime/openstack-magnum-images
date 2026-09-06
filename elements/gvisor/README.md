# gvisor

Installs gVisor (`runsc`) and its containerd shim, and registers a `gvisor`
runtime handler in containerd.

Enabled by default in the publish pipeline. Building by hand, add `gvisor` to
the `disk-image-create` element list:

```console
$ disk-image-create vm ubuntu-minimal block-device-kubernetes kubernetes gvisor
```

Then schedule onto it with a RuntimeClass. On a Magnum cluster
magnum-cluster-api creates this one for you; the object is only yours to write
when you built the node another way:

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: gvisor
```

## gVisor alongside Kata, not instead of it

The image ships both, so that a tenant picks per pod with `runtimeClassName`
instead of picking an image and a cluster. They fail in different places, which
is the reason to have both rather than the cheaper one.

`runsc` is a static userspace binary. With the default `systrap` platform it
needs no `/dev/kvm` and no kernel module, so it works wherever the node does -
including on a node with no hardware virtualisation available to it at all,
where every Kata handler bar the ptrace-free ones cannot start a pod.

Set `DIB_GVISOR_PLATFORM=kvm` only where `/dev/kvm` is known to be present in
the node itself. It is faster; it is also the one setting that gives `runsc`
the same prerequisite Kata has, and so gives up the property above.

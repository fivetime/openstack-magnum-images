# gvisor

Installs gVisor (`runsc`) and its containerd shim, and registers a `gvisor`
runtime handler in containerd.

Not enabled by default. Add `gvisor` to the `disk-image-create` element list:

```console
$ disk-image-create vm ubuntu-minimal block-device-kubernetes kubernetes gvisor
```

Then schedule onto it with a RuntimeClass:

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: gvisor
```

## Why gVisor and not Kata here

Kata needs a VMM, which needs hardware virtualisation inside the node. A
Magnum node is a guest on a compute node that is itself frequently a guest, so
a Kata VM would be a third level of nesting - supported on paper, unusable in
practice.

`runsc` is a static userspace binary. With the default `systrap` platform it
needs no `/dev/kvm` and no kernel module, so it works wherever the node does.
Set `DIB_GVISOR_PLATFORM=kvm` only where `/dev/kvm` is known to be present in
the node itself.

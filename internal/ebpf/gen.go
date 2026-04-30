package ebpf

//go:generate go run github.com/cilium/ebpf/cmd/bpf2go Muon ../../bpf/muon.c -- -D__TARGET_ARCH_${ARCH}

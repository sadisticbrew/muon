package tracer

import (
	"fmt"
	"log"
	"muon/internal/ebpf"

	gebpf "github.com/cilium/ebpf"
	"github.com/cilium/ebpf/link"
)

func linkTracepoints(objs *ebpf.MuonObjects) []link.Link {

	var links = []struct {
		name   string
		group  string
		symbol string
		prog   *gebpf.Program
	}{
		{"openat", "syscalls", "sys_enter_openat", objs.TraceOpenat},
		{"connect", "syscalls", "sys_enter_connect", objs.TraceConnect},
		{"fork", "sched", "sched_process_fork", objs.TraceForkAndClone},
		{"exit", "sched", "sched_process_exit", objs.TraceProcessExit},
		{"execve", "sched", "sched_process_exec", objs.TraceProcessExec},
		{"mmap", "syscalls", "sys_enter_mmap", objs.TraceMmap},
		{"mmap_exit", "syscalls", "sys_exit_mmap", objs.TraceMmapExit},
		{"brk", "syscalls", "sys_enter_brk", objs.TraceBrk},
		{"brk_exit", "syscalls", "sys_exit_brk", objs.TraceBrkExit},
		{"munmap", "syscalls", "sys_enter_munmap", objs.TraceMunmap},
	}

	result := make([]link.Link, 0, len(links))
	for _, l := range links {
		link, err := attachTracepoint(l.name, l.group, l.symbol, l.prog)
		if err != nil {
			log.Fatal(err)
		}
		result = append(result, link)
	}
	return result
}

func closeTracepoints(links []link.Link) {
	for _, l := range links {
		l.Close()
	}
}

func attachTracepoint(name, group, symbol string, prog *gebpf.Program) (link.Link, error) {
	l, err := link.Tracepoint(group, symbol, prog, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to attach %s: %w", name, err)
	}
	return l, nil
}

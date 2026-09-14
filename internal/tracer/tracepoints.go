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
		raw    bool
	}{
		{"openat", "syscalls", "sys_enter_openat", objs.TraceOpenat, false},
		{"connect", "syscalls", "sys_enter_connect", objs.TraceConnect, false},
		{"fork", "sched", "sched_process_fork", objs.TraceForkAndClone, true},
		{"exit", "sched", "sched_process_exit", objs.TraceProcessExit, false},
		{"execve", "sched", "sched_process_exec", objs.TraceProcessExec, false},
		{"mmap", "syscalls", "sys_enter_mmap", objs.TraceMmap, false},
		{"mmap_exit", "syscalls", "sys_exit_mmap", objs.TraceMmapExit, false},
		{"brk", "syscalls", "sys_enter_brk", objs.TraceBrk, false},
		{"brk_exit", "syscalls", "sys_exit_brk", objs.TraceBrkExit, false},
		{"munmap", "syscalls", "sys_enter_munmap", objs.TraceMunmap, false},
	}

	result := make([]link.Link, 0, len(links))
	for _, l := range links {
		link, err := attachTracepoint(l.name, l.group, l.symbol, l.prog, l.raw)
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

func attachTracepoint(name, group, symbol string, prog *gebpf.Program, raw bool) (link.Link, error) {
	if raw {
		l, err := link.AttachRawTracepoint(link.RawTracepointOptions{Name: symbol, Program: prog})
		if err != nil {
			return nil, fmt.Errorf("failed to attach raw tracepoint %s: %w", name, err)
		}
		return l, nil
	}
	l, err := link.Tracepoint(group, symbol, prog, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to attach %s: %w", name, err)
	}
	return l, nil
}

package tracer

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"log"
	"net/netip"
	"os"
	"os/signal"
	"syscall"

	"muon/internal/ebpf"

	"github.com/cilium/ebpf/link"
	"github.com/cilium/ebpf/ringbuf"
	"github.com/cilium/ebpf/rlimit"
)

type Event struct {
	PID     uint32
	Type    uint32
	Comm    [16]byte
	Fname   [256]byte
	RawAddr [128]byte
}

type ConnectCall struct {
	Addr   [16]byte
	Port   [6]byte
	Family uint16
}

func Monitor(targetPid uint32) {
	// Allow the current process to lock memory for eBPF resources.
	if err := rlimit.RemoveMemlock(); err != nil {
		log.Fatal(err)
	}

	spec, err := ebpf.LoadMuon()
	if err != nil {
		log.Fatalf("Failed to load bpf: %v", err)
	}

	if err := spec.Variables["target_pid"].Set(targetPid); err != nil {
		log.Fatalf("Failed to set target_pid: %v", err)
	}

	fmt.Println("Running program with target_pid set to", targetPid)

	var objs ebpf.MuonObjects
	if err := ebpf.LoadMuonObjects(&objs, nil); err != nil {
		log.Fatalf("Failed to load objects: %v", err)
	}
	defer objs.Close()

	// --------------------------tracepoints------------------------------

	tp_execve, err := link.Tracepoint("syscalls", "sys_enter_execve", objs.TraceExecve, nil)
	if err != nil {
		log.Fatalf("Failed to open tracepoint: %v", err)
	}
	defer tp_execve.Close()

	tp_openat, err := link.Tracepoint("syscalls", "sys_enter_openat", objs.TraceOpenat, nil)
	if err != nil {
		log.Fatalf("Failed to open tracepoint: %v", err)
	}
	defer tp_openat.Close()

	tp_enter_exit, err := link.Tracepoint("syscalls", "sys_enter_exit", objs.TraceExit, nil)
	if err != nil {
		log.Fatalf("Failed to open tracepoint: %v", err)
	}
	defer tp_enter_exit.Close()

	tp_enter_connect, err := link.Tracepoint("syscalls", "sys_enter_connect", objs.TraceConnect, nil)
	if err != nil {
		log.Fatalf("Failed to open tracepoint: %v", err)
	}
	defer tp_enter_connect.Close()

	// -------------------------------------------------------

	rd, err := ringbuf.NewReader(objs.Events)
	if err != nil {
		log.Fatalf("Failed to open ringbuf reader: %v", err)
	}
	defer rd.Close()

	log.Println("Muon is running! Waiting for openat calls... (Press Ctrl+C to stop)")

	// If you remove the go keyword, bad things might happen.
	go func() {
		var event Event
		for {

			record, err := rd.Read()
			if err != nil {
				log.Printf("Error reading from ring buffer: %v", err)
				continue
			}

			if err := binary.Read(bytes.NewBuffer(record.RawSample), binary.LittleEndian, &event); err != nil {
				log.Println(event)
				log.Printf("Error parsing event: %v", err)
				continue
			}

			fname := string(bytes.Trim((event.Fname[:]), "\x00"))

			switch event.Type {
			case 0:
				log.Printf("[exec] pid: %d, comm: %s, filename: %s\n", event.PID, string(event.Comm[:]), fname)
			case 1: //temporarily ignoring openat calls due to it's high volume
				log.Printf("[openat] pid: %d, comm: %s, filename: %s\n", event.PID, string(event.Comm[:]), fname)
			case 2:
				log.Printf("[exit] pid: %d, comm: %s\n", event.PID, string(event.Comm[:]))
			case 3:
				parseRawAddr(event)
			default:
				if event.Type != 1 {
					log.Printf("[unknown] pid: %d, comm: %s, filename: %s\n", event.PID, string(event.Comm[:]), fname)
				}
			}
		}
	}()

	stopper := make(chan os.Signal, 1)
	signal.Notify(stopper, os.Interrupt, syscall.SIGTERM)
	<-stopper
	log.Println("Exiting Muon...")
}

func parseRawAddr(event Event) {
	family := binary.NativeEndian.Uint16(event.RawAddr[0:2])
	log.Println(family)
	switch family {
	case syscall.AF_INET:
		port := binary.BigEndian.Uint16(event.RawAddr[2:4])
		addr, ok := netip.AddrFromSlice(bytes.Trim(event.RawAddr[4:8], "\x00"))
		if !ok {
			log.Println("Invalid address: ", event.RawAddr[4:])
		}
		log.Printf("[connnect] pid: %d, comm: %s, addr: %s:%d\n", event.PID, string(event.Comm[:]), addr.String(), port)
	case syscall.AF_INET6:
		port := binary.BigEndian.Uint16(event.RawAddr[2:4])
		addr, ok := netip.AddrFromSlice(bytes.Trim(event.RawAddr[8:24], "\x00"))
		if !ok {
			log.Println("Invalid address: ", event.RawAddr[8:24])
		}
		log.Printf("[connnect] pid: %d, comm: %s, addr: %s:%d\n", event.PID, string(event.Comm[:]), addr.String(), port)
	case syscall.AF_UNIX:
		addr := string(bytes.Trim(event.RawAddr[2:], "\x00"))
		log.Printf("[connnect] pid: %d, comm: %s, addr: %s\n", event.PID, string(event.Comm[:]), addr)
	}
}

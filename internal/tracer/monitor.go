package tracer

import (
	"bytes"
	"encoding/binary"
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
	PID  uint32
	Type uint32
	Comm [16]byte
	Data struct {
		Data [256]byte
	}
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

	var objs ebpf.MuonObjects
	if err := spec.LoadAndAssign(&objs, nil); err != nil {
		log.Fatalf("Failed to load objects: %v", err)
	}
	defer objs.Close()

	objs.MuonMaps.TrackedPids.Put(&targetPid, &targetPid)

	log.Println("Running program with target_pid set to", targetPid)

	// --------------------------tracepoints------------------------------

	tp_openat, err := link.Tracepoint("syscalls", "sys_enter_openat", objs.TraceOpenat, nil)
	if err != nil {
		log.Fatalf("Failed to open tracepoint: %v", err)
	}
	defer tp_openat.Close()

	tp_enter_connect, err := link.Tracepoint("syscalls", "sys_enter_connect", objs.TraceConnect, nil)
	if err != nil {
		log.Fatalf("Failed to open tracepoint: %v", err)
	}
	defer tp_enter_connect.Close()

	tp_sched_process_fork, err := link.Tracepoint("sched", "sched_process_fork", objs.TraceForkAndClone, nil)
	if err != nil {
		log.Fatalf("Failed to open tracepoint: %v", err)
	}
	defer tp_sched_process_fork.Close()

	tp_process_exit, err := link.Tracepoint("sched", "sched_process_exit", objs.TraceProcessExit, nil)
	if err != nil {
		log.Fatalf("Failed to open tracepoint: %v", err)
	}
	defer tp_process_exit.Close()

	tp_execve, err := link.Tracepoint("sched", "sched_process_exec", objs.TraceProcessExec, nil)
	if err != nil {
		log.Fatalf("Failed to open tracepoint: %v", err)
	}
	defer tp_execve.Close()

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

			nullIdx := bytes.Index(event.Data.Data[:], []byte{0})
			var fname string
			if nullIdx == -1 {
				fname = string(event.Data.Data[:])
			} else {
				fname = string(event.Data.Data[:nullIdx])
			}
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

	var key uint32 = 0
	// Because it's a Per-CPU array, we get a slice of values (one for each CPU core)
	var perCPUCounts []uint64

	err = objs.MuonMaps.DropCounter.Lookup(&key, &perCPUCounts)
	if err == nil {
		var totalDrops uint64 = 0
		for _, count := range perCPUCounts {
			totalDrops += count
		}
		if totalDrops > 0 {
			log.Printf("WARNING: Ring buffer was full! Dropped %d events.\n", totalDrops)
		} else {
			log.Println("Success: 0 events dropped!")
		}
	} else {
		log.Printf("Failed to read drop counter: %v", err)
	}
}

func parseRawAddr(event Event) {
	family := binary.NativeEndian.Uint16(event.Data.Data[0:2])
	log.Println(family)
	switch family {
	case syscall.AF_INET:
		port := binary.BigEndian.Uint16(event.Data.Data[2:4])
		addr, ok := netip.AddrFromSlice(event.Data.Data[4:8])
		if !ok {
			log.Println("Invalid address: ", event.Data.Data[4:8])
		}
		log.Printf("[connnect] pid: %d, comm: %s, addr: %s:%d\n", event.PID, string(event.Comm[:]), addr.String(), port)
	case syscall.AF_INET6:
		port := binary.BigEndian.Uint16(event.Data.Data[2:4])
		addr, ok := netip.AddrFromSlice(event.Data.Data[8:24])
		if !ok {
			log.Println("Invalid address: ", event.Data.Data[8:24])
		}
		log.Printf("[connnect] pid: %d, comm: %s, addr: %s:%d\n", event.PID, string(event.Comm[:]), addr.String(), port)
	case syscall.AF_UNIX:
		addr := string(bytes.Trim(event.Data.Data[2:], "\x00"))
		log.Printf("[connnect] pid: %d, comm: %s, addr: %s\n", event.PID, string(event.Comm[:]), addr)
	}
}

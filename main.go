package main

import (
	"bytes"
	"encoding/binary"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/cilium/ebpf/link"
	"github.com/cilium/ebpf/ringbuf"
	"github.com/cilium/ebpf/rlimit"
)

type Event struct {
	PID   uint32
	Type  uint32
	Comm  [16]byte
	Fname [256]byte
}

func main() {
	// Allow the current process to lock memory for eBPF resources.
	if err := rlimit.RemoveMemlock(); err != nil {
		log.Fatal(err)
	}

	var objs bpfObjects
	if err := loadBpfObjects(&objs, nil); err != nil {
		log.Fatalf("Failed to load objects: %v", err)
	}
	defer objs.Close()

	tp1, err := link.Tracepoint("syscalls", "sys_enter_execve", objs.TraceExecve, nil)
	if err != nil {
		log.Fatalf("Failed to open tracepoint: %v", err)
	}
	defer tp1.Close()

	tp2, err := link.Tracepoint("syscalls", "sys_enter_openat", objs.TraceOpenat, nil)
	if err != nil {
		log.Fatalf("Failed to open tracepoint: %v", err)
	}
	defer tp2.Close()

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

			switch event.Type {
			case 0:
				log.Printf("[exec] pid: %d, comm: %s, filename: %s\n", event.PID, string(event.Comm[:]), string(event.Fname[:]))
			case 1:
				log.Printf("[openat] pid: %d, comm: %s, filename: %s\n", event.PID, string(event.Comm[:]), string(event.Fname[:]))
			default:
				log.Printf("[unknown] pid: %d, comm: %s, filename: %s\n", event.PID, string(event.Comm[:]), string(event.Fname[:]))
			}

		}
	}()

	stopper := make(chan os.Signal, 1)
	signal.Notify(stopper, os.Interrupt, syscall.SIGTERM)
	<-stopper
	log.Println("Exiting Muon...")
}

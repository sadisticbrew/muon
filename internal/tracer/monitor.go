package tracer

import (
	"bytes"
	"context"
	"encoding/binary"
	"log"
	"os"
	"os/signal"
	"sync"
	"syscall"

	"muon/internal/ebpf"
	"muon/internal/loader"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/cilium/ebpf/ringbuf"
)

var parsedEventsMu sync.Mutex
var parsedEvents []ParsedEvent

func Monitor(targetPid uint32, p *tea.Program) {

	/*	Load and assign ebpf objects  */
	objs := loader.Load(targetPid)
	defer objs.Close()

	/*link to tracepoints */
	links := linkTracepoints(objs)
	defer closeTracepoints(links)

	// -------------------------------------------------------
	rd, err := ringbuf.NewReader(objs.Events)
	if err != nil {
		log.Fatalf("Failed to open ringbuf reader: %v", err)
	}
	defer rd.Close()

	log.Println("Muon is running! Waiting for openat calls... (Press Ctrl+C to stop)")

	// ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	var wg sync.WaitGroup

	wg.Add(1)

	// If you remove the go keyword, bad things might happen.
	go func(ctx context.Context) {
		defer wg.Done()
		var event Event
		for {
			select {
			case <-ctx.Done():
				log.Println(parsedEvents)

				return
			default:
				record, err := rd.Read()
				if err != nil {
					if err == ringbuf.ErrClosed {
						return
					}
					log.Printf("Error reading from ring buffer: %v", err)
					continue
				}

				if err := binary.Read(bytes.NewBuffer(record.RawSample), binary.LittleEndian, &event); err != nil {
					log.Println(event)
					log.Printf("Error parsing event: %v", err)
					continue
				}

				if handler, ok := handlers[event.Type]; ok {
					parsedEvent := handler(event, objs)
					parsedEvents = append(parsedEvents, parsedEvent)
				} else {
					if event.Type != 1 {
						fname := makeFilename(event)
						log.Printf("[unknown] pid: %d, comm: %s, filename: %s\n", event.PID, string(event.Comm[:]), fname)
					}
				}

			}
		}
	}(ctx)

	<-ctx.Done()
	rd.Close()
	log.Println("Exiting Muon...")
	wg.Wait()
	log.Println("Exit successful.")

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

func cleanupAfterExit(objs *ebpf.MuonObjects, pid uint32) {
	var alloc_key AllocKey
	var size uint64
	iter := objs.MuonMaps.ActiveAllocs.Iterate()
	for iter.Next(&alloc_key, &size) {
		if alloc_key.PID == pid {
			objs.MuonMaps.ActiveAllocs.Delete(&alloc_key)
		}
	}
}

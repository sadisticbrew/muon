package tracer

import (
	"context"
	"log"
	"os"
	"os/signal"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"

	"muon/internal/loader"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/cilium/ebpf/ringbuf"
)

var UserspaceDrops atomic.Int64
var manager = NewManager()
var batchChan = make(chan []*ParsedEvent, 50000)
var cleanupChan = make(chan uint32, 10000)
var eventPool = sync.Pool{
	New: func() any {
		return new(ParsedEvent)
	},
}

func Monitor(targetPid uint32, p *tea.Program) {
	objs := loader.Load(targetPid)
	defer objs.Close()

	links := linkTracepoints(objs)
	defer closeTracepoints(links)

	rd, err := ringbuf.NewReader(objs.Events)
	if err != nil {
		log.Fatalf("Failed to open ringbuf reader: %v", err)
	}
	defer rd.Close()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	var wg sync.WaitGroup

	wg.Add(1)
	go func() {
		defer wg.Done()
		manager.StartWorker(ctx, batchChan, &eventPool)
	}()

	// drain the incoming events from ringbuff as fast as possible
	wg.Add(1)
	go func() {
		defer wg.Done()
		var header *EventHeader
		var batch = make([]*ParsedEvent, 0, 1000)
		var payload []byte
		const minHeaderSize = 32

		for {
			select {
			case <-ctx.Done():
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
				if len(record.RawSample) < minHeaderSize {
					log.Println("Skipping malformed event: payload too small for header")
					continue
				}

				header = (*EventHeader)(unsafe.Pointer(unsafe.SliceData(record.RawSample)))
				payload = record.RawSample[28:]

				// Prevent panic if an unknown event type is sent
				if int(header.Type) >= len(handlers) {
					continue
				}

				if header.Type == 4 || header.Type == 5 {
					if len(payload) < 18 { // 18 is size of alloc_event
						log.Println("Skipping malformed alloc event")
						continue
					}
				} else if len(payload) < int(unsafe.Sizeof(EventHeader{})) {
					log.Println("Skipping malformed full event")
					continue
				}

				parsedEvent := eventPool.Get().(*ParsedEvent)

				handler := handlers[header.Type]
				handler(header, objs, parsedEvent, payload) // Passing slice instead of unsafe pointer
				batch = append(batch, parsedEvent)

				if len(batch) == 1000 {
					select {
					case batchChan <- batch:
					default:
						for _, e := range batch {
							eventPool.Put(e)
						}
						UserspaceDrops.Add(1000) // Log the userspace drop
					}
					batch = make([]*ParsedEvent, 0, 1000)
				}
			}
		}
	}()

	// pushes every 16ms
	wg.Add(1)
	go func() {
		defer wg.Done()
		ticker := time.NewTicker(16 * time.Millisecond) // 60 FPS
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				p.Send(manager.Snapshot())
			}
		}
	}()

	// monitor ringbuf drops.
	wg.Add(1)
	go func() {
		defer wg.Done()
		ticker := time.NewTicker(1 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				var key uint32
				var perCPUCounts []uint64
				if err := objs.MuonMaps.DropCounter.Lookup(&key, &perCPUCounts); err != nil {
					log.Printf("Failed to read drop counter: %v", err)
					continue
				}
				var totalDrops uint64
				for _, c := range perCPUCounts {
					totalDrops += c
				}
				if totalDrops > 0 {
					manager.SetDropCount(totalDrops)
				}
			}
		}
	}()

	// clean up exited processes
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			select {
			case <-ctx.Done():
				return
			case pid := <-cleanupChan:
				var allocKey AllocKey
				var size uint64
				var totalFreed uint64
				iter := objs.MuonMaps.ActiveAllocs.Iterate()
				for iter.Next(&allocKey, &size) {
					if allocKey.PID == pid {
						totalFreed += size
						objs.MuonMaps.ActiveAllocs.Delete(&allocKey)
					}
				}
				manager.CleanUpOnProcessExit(totalFreed)
			}
		}
	}()

	<-ctx.Done()
	rd.Close()
	wg.Wait()
	log.Println("Exit successful.")
}

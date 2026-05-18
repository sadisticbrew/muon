package tracer

import (
	"context"
	"fmt"
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
var batchChan = make(chan ParsedEventBatch, 1000) // ~86MB
var metricChan = make(chan MemFreed, 60)          // ~0.9KB
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
		manager.StartWorker(ctx, batchChan, metricChan, &eventPool)
	}()

	// drain the incoming events from ringbuff as fast as possible
	wg.Add(1)
	go func() {
		defer wg.Done()
		var header *EventHeader
		var currentBatch ParsedEventBatch = make(ParsedEventBatch, 0, BATCH_SIZE)
		var payload []byte
		var payloadLen int
		headerSize := int(unsafe.Sizeof(EventHeader{}))
		var flushTick = time.NewTicker(50 * time.Millisecond)
		for {
			select {
			case <-ctx.Done():
				return
			case <-flushTick.C:
				if len(currentBatch) > 0 {
					select {
					case batchChan <- currentBatch:
					default:
						for _, e := range currentBatch {
							*e = ParsedEvent{}
							eventPool.Put(e)
						}
						UserspaceDrops.Add(int64(BATCH_SIZE)) // Log the userspace drop
					}
					currentBatch = make(ParsedEventBatch, 0, BATCH_SIZE)
				}
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
				payload = record.RawSample[headerSize:]
				payloadLen = len(payload)

				// Prevent panic if an unknown event type is sent
				if int(header.Type) >= len(handlers) {
					continue
				}

				if header.Type == 4 || header.Type == 5 {
					if payloadLen < 18 { // 18 is size of alloc_event
						log.Println("Skipping malformed alloc event")
						continue
					}
				} else if payloadLen < headerSize {
					log.Println("Skipping malformed full event")
					continue
				}

				parsedEvent := eventPool.Get().(*ParsedEvent)

				handler := handlers[header.Type]
				handler(header, objs, parsedEvent, payload) // Passing slice instead of unsafe pointer
				currentBatch = append(currentBatch, parsedEvent)

				if len(currentBatch) == BATCH_SIZE {
					select {
					case batchChan <- currentBatch:
					default:
						for _, e := range currentBatch {
							*e = ParsedEvent{}
							eventPool.Put(e)
						}
						UserspaceDrops.Add(int64(BATCH_SIZE)) // Log the userspace drop
					}
					currentBatch = make([]*ParsedEvent, 0, BATCH_SIZE)
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
				var pid uint32
				var mem uint64
				var totalMem int64

				iter := objs.MuonMaps.HeapTotals.Iterate()
				for iter.Next(&pid, &mem) {
					totalMem += int64(mem)
				}

				manager.state.activeMemory.Store(totalMem)

				for {
					peak := manager.state.peakMemory.Load()
					if totalMem <= peak || manager.state.peakMemory.CompareAndSwap(peak, totalMem) {
						break
					}
				}
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
		var memFreed = MemFreed{From: 0}
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
					memFreed.TotalFreed = totalDrops
					metricChan <- memFreed
				}
			}
		}
	}()

	// janitor go routine
	wg.Add(1)
	go func() {
		var allocKey AllocKey
		var size uint64
		var pid uint64

		defer wg.Done()
		ticker := time.NewTicker(30 * time.Second)

		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				for iter := objs.MuonMaps.ActiveAllocs.Iterate(); iter.Next(&allocKey, &size); {
					if _, err := os.Stat(fmt.Sprintf("/proc/%d", allocKey.PID)); os.IsNotExist(err) {
						objs.MuonMaps.ActiveAllocs.Delete(&allocKey)
					}
				}
				for iter := objs.MuonMaps.PendingMmaps.Iterate(); iter.Next(&pid, &size); {
					if _, err := os.Stat(fmt.Sprintf("/proc/%d", pid)); os.IsNotExist(err) {
						objs.MuonMaps.PendingMmaps.Delete(&pid)
					}
				}
				for iter := objs.MuonMaps.PendingBrks.Iterate(); iter.Next(&pid, &size); {
					if _, err := os.Stat(fmt.Sprintf("/proc/%d", pid)); os.IsNotExist(err) {
						objs.MuonMaps.PendingBrks.Delete(&pid)
					}
				}
			}
		}

	}()

	<-ctx.Done()
	rd.Close()
	wg.Wait()
	log.Println("Exit successful.")
}

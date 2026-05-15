package tracer

import (
	"context"
	"sync"
	"sync/atomic"
	"time"
)

var count = new(int(0))
var snapshot = new(MuonState)

type muonInternalState struct {
	activeMemory atomic.Int64
	peakMemory   atomic.Int64
	totalAllocd  atomic.Uint64
	totalFreed   atomic.Uint64
	recentEvents *RingBuff
	uspaceDrops  atomic.Int64
	dropCount    atomic.Uint64
}

type Manager struct {
	state       muonInternalState
	uiState     atomic.Value
	uiEventBuff [200]*ParsedEvent
}

func NewManager() *Manager {
	return &Manager{
		state: muonInternalState{
			recentEvents: NewRingBuff(16000),
		},
	}
}

func (m *Manager) StartWorker(ctx context.Context, parsedEventBatches <-chan ParsedEventBatch, metricBatch <-chan MemFreed, pool *sync.Pool) {
	ticker := time.NewTicker(16 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case batch := <-parsedEventBatches:
			for _, event := range batch {
				evicted := m.processEvent(event)
				if evicted != nil {
					*evicted = ParsedEvent{}
					pool.Put(evicted)
				}
			}
		case memFree := <-metricBatch:
			switch memFree.From {
			case 0:
				m.state.dropCount.Store(memFree.TotalFreed)
			case 1:
				m.state.totalFreed.Add(memFree.TotalFreed)
			}
		case <-ticker.C:
			snap := &MuonState{
				ActiveMemory: m.state.activeMemory.Load(),
				PeakMemory:   m.state.peakMemory.Load(),
				DropCount:    m.state.dropCount.Load(),
				UspaceDrops:  m.state.uspaceDrops.Load(),
				// We pass a "view" into the ring buffer
				RecentEvents: m.state.recentEvents.Emit(200),
			}
			m.uiState.Store(snap)
		}
	}
}

func (m *Manager) processEvent(event *ParsedEvent) *ParsedEvent {

	evicted := m.state.recentEvents.Push(event)

	switch event.Kind {
	case "mmap":
		m.state.totalAllocd.Add(event.RawSize)
	case "munmap", "munmap_no_history":
		m.state.totalFreed.Add(event.RawSize)
	case "brk":
		switch event.Flag {
		case ALLOC:
			m.state.totalAllocd.Add(event.RawSize)
		case FREE:
			m.state.totalFreed.Add(event.RawSize)
		}
	}
	return evicted
}

func (m *Manager) Snapshot() *MuonState {
	val := m.uiState.Load()
	if val == nil {
		return new(MuonState)
	}
	return val.(*MuonState)
}

func (m *Manager) CleanUpOnProcessExit(size uint64) {
	m.state.activeMemory.Add(-int64(size))
	m.state.totalFreed.Add(size)

}

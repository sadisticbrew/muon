package tracer

import "sync"

type RingBuff struct {
	data  []*ParsedEvent
	size  int
	write int
	mu    sync.RWMutex
}

func NewRingBuff(size int) *RingBuff {
	return &RingBuff{
		data:  make([]*ParsedEvent, size),
		size:  size,
		write: -1,
	}
}

func (r *RingBuff) Push(event *ParsedEvent) *ParsedEvent {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.write == -1 {
		r.write = 0
		r.data[r.write] = event
		return nil
	}

	lastEvent := r.data[r.write]
	if lastEvent.cmpParsedEvent(event) {
		lastEvent.Count += 1
		return event
	}
	r.write = (r.write + 1) % r.size
	evicted := r.data[r.write]
	r.data[r.write] = event

	return evicted
}

func (r *RingBuff) Emit(n int) []ParsedEvent {
	r.mu.RLock()
	defer r.mu.RUnlock()

	if r.write == -1 {
		return nil
	}
	if n > r.size {
		n = r.size
	}

	result := make([]ParsedEvent, 0, n)

	for i := 0; i < n; i++ {
		index := r.write - i
		if index < 0 {
			index += r.size
		}
		if r.data[index] == nil {
			break
		}

		result = append(result, *r.data[index])
	}

	return result
}

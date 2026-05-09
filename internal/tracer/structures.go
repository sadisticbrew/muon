package tracer

type RingBuff struct {
	data  []*ParsedEvent
	size  int
	write int
}

func NewRingBuff(size int) *RingBuff {
	return &RingBuff{
		data:  make([]*ParsedEvent, size),
		size:  size,
		write: -1,
	}
}

func (r *RingBuff) Push(event *ParsedEvent) {
	if r.write == -1 {
		r.write = 0
		r.data[r.write] = event
		return
	}

	lastEvent := r.data[r.write]

	if lastEvent.cmpParsedEvent(event) {
		r.data[r.write].Count += 1
		return
	}
	r.write = (r.write + 1) % r.size
	r.data[r.write] = event
}

func (r *RingBuff) Emit(n int) []*ParsedEvent {
	var result []*ParsedEvent

	if r.write == -1 {
		return result
	}
	if n > r.size {
		n = r.size
	}
	for i := 0; i < n; i++ {
		index := r.write - i
		if index < 0 {
			index += r.size
		}
		result = append(result, r.data[index])
	}

	return result
}

func (r *RingBuff) Fill(dest []*ParsedEvent) int {
	if r.write == -1 {
		return 0
	}
	count := 0
	for i := 0; i < len(dest); i++ {
		index := r.write - i
		if index < 0 {
			index += r.size
		}
		dest[i] = r.data[index]
		count++
	}
	return count
}

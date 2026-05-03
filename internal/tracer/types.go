package tracer

const (
	ALLOC           uint16 = 0
	FREE            uint16 = 1
	FREE_NO_HISTORY uint16 = 2
)

type Event struct {
	PID  uint32
	Type uint32
	Comm [16]byte
	Data [256]byte
}

type AllocEventData struct {
	Addr uint64
	Size uint64
	Flag uint16
}

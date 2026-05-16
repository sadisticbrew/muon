package tracer

const (
	ALLOC           uint16 = 0
	FREE            uint16 = 1
	FREE_NO_HISTORY uint16 = 2
	BATCH_SIZE      int    = 1024
	minHeaderSize   int    = 32
)

type ParsedEventBatch []*ParsedEvent

type EventHeader struct {
	PID       uint32
	Type      uint32
	Timestamp uint64
	Comm      [16]byte
}

type AllocEventData struct {
	Addr uint64
	Size uint64
	Flag uint16
}

type AllocKey struct {
	Addr uint64
	PID  uint32
}

type MemFreed struct {
	From       int
	TotalFreed uint64
}

type ParsedEvent struct {
	PID       uint32
	Comm      [16]byte
	Timestamp uint64
	Kind      string
	Detail    [256]byte
	RawSize   uint64
	RawAddr   uint64
	Flag      uint16
	Count     int64
}

type MuonState struct {
	ActiveMemory int64
	PeakMemory   int64
	TotalAllocd  uint64
	TotalFreed   uint64
	RecentEvents []ParsedEvent // TUI gets its own cloned copy
	DropCount    uint64
	UspaceDrops  int64
}

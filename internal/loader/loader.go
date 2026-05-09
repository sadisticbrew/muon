package loader

import (
	"errors"
	"fmt"
	"log"
	"muon/internal/ebpf"

	gebpf "github.com/cilium/ebpf"
	"github.com/cilium/ebpf/rlimit"
)

func Load(targetPid uint32) *ebpf.MuonObjects {
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
		// log.Fatalf("Failed to load objects: %v", err)
		var ve *gebpf.VerifierError
		if errors.As(err, &ve) {
			fmt.Printf("Detailed Verifier Error:\n%+v\n", ve)
		} else {
			fmt.Printf("Load failed: %v\n", err)
		}
	}

	objs.MuonMaps.TrackedPids.Put(&targetPid, &targetPid)

	// log.Println("Running program with target_pid set to", targetPid)

	return &objs
}

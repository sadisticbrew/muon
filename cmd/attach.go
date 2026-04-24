package cmd

import (
	"errors"
	"muon/internal/tracer"

	"github.com/spf13/cobra"
)

var targetPid uint32

var attachCmd = &cobra.Command{
	Use:   "attach",
	Short: "Attach Muon to a specific process",
	RunE: func(cmd *cobra.Command, args []string) error {
		if targetPid == 0 {
			return errors.New("Target pid is required")
		}
		// Pass the PID to the engine and let it take over
		tracer.Monitor(targetPid)
		return nil
	},
}

func init() {
	rootCmd.AddCommand(attachCmd)
	attachCmd.Flags().Uint32VarP(&targetPid, "target_pid", "p", 0, "target process id")
	attachCmd.MarkFlagRequired("target_pid")
}

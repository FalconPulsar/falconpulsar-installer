// SPDX-License-Identifier: AGPL-3.0-only
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/falconpulsar/falconpulsar-installer/console/internal/rehearsal"
)

func run(args []string) (any, error) {
	if len(args) == 0 || (args[0] != "inspect" && args[0] != "restore") {
		return nil, fmt.Errorf("usage: fp-rehearse inspect --archive FILE | restore --archive FILE --destination NEW_DIR")
	}
	flags := flag.NewFlagSet(args[0], flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	archive := flags.String("archive", "", "native FalconPulsar data backup")
	destination := flags.String("destination", "", "new private restore directory")
	if err := flags.Parse(args[1:]); err != nil {
		return nil, err
	}
	if *archive == "" || flags.NArg() != 0 {
		return nil, fmt.Errorf("--archive FILE is required; positional arguments are not accepted")
	}
	if args[0] == "inspect" {
		if *destination != "" {
			return nil, fmt.Errorf("inspect does not accept a destination")
		}
		return rehearsal.Inspect(*archive)
	}
	if *destination == "" {
		return nil, fmt.Errorf("restore requires --destination NEW_DIR")
	}
	return rehearsal.Restore(context.Background(), *archive, *destination)
}

func main() {
	result, err := run(os.Args[1:])
	if err != nil {
		operation := ""
		if len(os.Args) > 1 {
			operation = os.Args[1]
		}
		_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"schema_version": 1, "operation": operation, "status": "error", "error": err.Error()})
		os.Exit(1)
	}
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

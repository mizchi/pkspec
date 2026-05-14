package main

import (
	"fmt"
	"os"

	"github.com/mizchi/pkspec/internal/adaptershim"
)

func main() {
	if err := adaptershim.Run(adaptershim.KindPlaywright, os.Args[1:], os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

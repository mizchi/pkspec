// Package pkspec exposes the Pkl schemas that are needed to author
// pkspec test modules from an installed binary.
package pkspec

import "embed"

// SchemaFS contains the public Pkl authoring schemas.
//
//go:embed pkl/Test.pkl pkl/Spec.pkl pkl/QuickCheck.pkl
var SchemaFS embed.FS

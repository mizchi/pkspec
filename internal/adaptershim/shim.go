package adaptershim

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	pathpkg "path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

const (
	KindVitest     = "vitest"
	KindPlaywright = "playwright"
	KindNodeTest   = "node-test"
	KindGoTest     = "go-test"
	KindMoonTest   = "moon-test"
)

type Case struct {
	ID           string            `json:"id"`
	Name         *string           `json:"name,omitempty"`
	SourceModule *string           `json:"sourceModule,omitempty"`
	ExportName   *string           `json:"exportName,omitempty"`
	Selector     map[string]string `json:"selector,omitempty"`
	Params       map[string]any    `json:"params,omitempty"`
	SpecRef      []string          `json:"specRef,omitempty"`
	Tags         []string          `json:"tags,omitempty"`
	Pending      bool              `json:"pending,omitempty"`
	TimeoutSec   *int              `json:"timeoutSec,omitempty"`
	BatchKey     string            `json:"batchKey,omitempty"`
}

type Manifest struct {
	Protocol string         `json:"protocol"`
	Suite    string         `json:"suite"`
	Adapter  string         `json:"adapter"`
	Config   map[string]any `json:"config"`
	Cases    []Case         `json:"cases"`
}

type Event struct {
	Type       string  `json:"type"`
	CaseID     string  `json:"caseId"`
	Outcome    string  `json:"outcome,omitempty"`
	DurationMs float64 `json:"durationMs,omitempty"`
	Message    string  `json:"message,omitempty"`
}

type stringList []string

func (s *stringList) String() string {
	return strings.Join(*s, ",")
}

func (s *stringList) Set(value string) error {
	*s = append(*s, value)
	return nil
}

type discoverOptions struct {
	config          string
	specDir         string
	nodeBin         string
	goBin           string
	moonBin         string
	testNamePattern string
	runPattern      string
	include         []string
	exclude         []string
	paths           []string
	packages        []string
	projects        []string
	grep            []string
	targets         []string
	pool            string
}

type runOptions struct {
	config          string
	manifestPath    string
	nodeBin         string
	goBin           string
	moonBin         string
	testReporter    string
	count           string
	update          bool
	updateSnapshots bool
	pool            string
	projects        []string
	workers         string
	target          string
}

// Run executes a native adapter shim command.
func Run(kind string, args []string, stdout, stderr io.Writer) error {
	if len(args) == 0 {
		return fmt.Errorf("usage: pkspec-adapter-%s <discover|run|coverage>", kind)
	}
	switch args[0] {
	case "discover":
		return runDiscover(kind, args[1:], stdout, stderr)
	case "run":
		return runManifest(kind, args[1:], stdout, stderr)
	case "coverage":
		return runCoverage(kind, args[1:], stdout)
	case "-h", "--help", "help":
		_, _ = fmt.Fprintf(stdout, "usage: pkspec-adapter-%s <discover|run|coverage>\n", kind)
		return nil
	default:
		return fmt.Errorf("unknown adapter shim command %q", args[0])
	}
}

func runDiscover(kind string, args []string, stdout, stderr io.Writer) error {
	opts, err := parseDiscoverFlags(kind, args, stderr)
	if err != nil {
		return err
	}
	var cases []Case
	switch kind {
	case KindVitest:
		cases, err = discoverJS(jsDiscoverOptions{
			inputs:      defaultStrings(opts.include, []string{"."}),
			excludes:    opts.exclude,
			namePattern: opts.testNamePattern,
			defaultRoot: ".",
		})
	case KindPlaywright:
		pattern := opts.testNamePattern
		if pattern == "" && len(opts.grep) > 0 {
			pattern = strings.Join(opts.grep, "|")
		}
		cases, err = discoverJS(jsDiscoverOptions{
			inputs:      []string{defaultString(opts.specDir, "tests")},
			excludes:    opts.exclude,
			namePattern: pattern,
			defaultRoot: defaultString(opts.specDir, "tests"),
		})
	case KindNodeTest:
		cases, err = discoverJS(jsDiscoverOptions{
			inputs:      defaultStrings(opts.paths, []string{"."}),
			excludes:    opts.exclude,
			namePattern: opts.testNamePattern,
			defaultRoot: ".",
		})
	case KindGoTest:
		cases, err = discoverGo(opts.goBin, defaultStrings(opts.packages, []string{"."}), opts.runPattern)
	case KindMoonTest:
		cases, err = discoverMoon(defaultStrings(opts.packages, []string{"."}), opts.targets)
	default:
		err = fmt.Errorf("unsupported adapter kind %q", kind)
	}
	if err != nil {
		return err
	}
	sortCases(cases)
	return json.NewEncoder(stdout).Encode(map[string][]Case{"cases": cases})
}

func parseDiscoverFlags(kind string, args []string, stderr io.Writer) (discoverOptions, error) {
	var opts discoverOptions
	fs := flag.NewFlagSet("discover", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.StringVar(&opts.config, "config", "", "runner config path")
	fs.StringVar(&opts.specDir, "spec-dir", "", "spec directory")
	fs.StringVar(&opts.nodeBin, "node", "node", "node binary")
	fs.StringVar(&opts.goBin, "go", "go", "go binary")
	fs.StringVar(&opts.moonBin, "moon", "moon", "moon binary")
	fs.StringVar(&opts.testNamePattern, "test-name-pattern", "", "test name pattern")
	fs.StringVar(&opts.runPattern, "run", ".", "go test list pattern")
	fs.StringVar(&opts.pool, "pool", "", "vitest pool")
	var include, exclude, paths, packages, projects, grep, targets stringList
	fs.Var(&include, "include", "include glob")
	fs.Var(&exclude, "exclude", "exclude glob")
	fs.Var(&paths, "path", "test path")
	fs.Var(&packages, "package", "package path")
	fs.Var(&projects, "project", "playwright project")
	fs.Var(&grep, "grep", "playwright grep")
	fs.Var(&targets, "target", "moon target")
	if err := fs.Parse(args); err != nil {
		return opts, err
	}
	opts.include = include
	opts.exclude = exclude
	opts.paths = append(paths, fs.Args()...)
	opts.packages = packages
	opts.projects = projects
	opts.grep = grep
	opts.targets = targets
	return opts, nil
}

func runManifest(kind string, args []string, stdout, stderr io.Writer) error {
	opts, err := parseRunFlags(kind, args, stderr)
	if err != nil {
		return err
	}
	manifestPath := opts.manifestPath
	if manifestPath == "" {
		manifestPath = os.Getenv("PKSPEC_CASE_MANIFEST")
	}
	if manifestPath == "" {
		return errors.New("missing --manifest or PKSPEC_CASE_MANIFEST")
	}
	manifest, err := readManifest(manifestPath)
	if err != nil {
		return err
	}
	enc := json.NewEncoder(stdout)
	for _, tc := range manifest.Cases {
		if tc.ID == "" {
			return errors.New("manifest case is missing id")
		}
		if err := enc.Encode(Event{Type: "caseStart", CaseID: tc.ID}); err != nil {
			return err
		}
		if tc.Pending {
			if err := enc.Encode(Event{Type: "caseFinish", CaseID: tc.ID, Outcome: "pending"}); err != nil {
				return err
			}
			continue
		}
		started := time.Now()
		ok, message := executeCase(kind, opts, manifest, tc, stderr)
		outcome := "passed"
		if !ok {
			outcome = "failed"
		}
		if err := enc.Encode(Event{
			Type:       "caseFinish",
			CaseID:     tc.ID,
			Outcome:    outcome,
			DurationMs: float64(time.Since(started).Microseconds()) / 1000,
			Message:    message,
		}); err != nil {
			return err
		}
	}
	return nil
}

func parseRunFlags(kind string, args []string, stderr io.Writer) (runOptions, error) {
	var opts runOptions
	fs := flag.NewFlagSet("run", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.StringVar(&opts.config, "config", "", "runner config path")
	fs.StringVar(&opts.manifestPath, "manifest", "", "case manifest path")
	fs.StringVar(&opts.nodeBin, "node", "node", "node binary")
	fs.StringVar(&opts.goBin, "go", "go", "go binary")
	fs.StringVar(&opts.moonBin, "moon", "moon", "moon binary")
	fs.StringVar(&opts.testReporter, "test-reporter", "tap", "node test reporter")
	fs.StringVar(&opts.count, "count", "", "go test count")
	fs.StringVar(&opts.pool, "pool", "", "vitest pool")
	fs.StringVar(&opts.workers, "workers", "", "playwright worker count")
	fs.StringVar(&opts.target, "target", "", "moon target")
	fs.BoolVar(&opts.update, "update", false, "update fixtures")
	fs.BoolVar(&opts.updateSnapshots, "update-snapshots", false, "update snapshots")
	var projects stringList
	fs.Var(&projects, "project", "playwright project")
	if err := fs.Parse(args); err != nil {
		return opts, err
	}
	opts.projects = projects
	return opts, nil
}

func readManifest(path string) (Manifest, error) {
	f, err := os.Open(path)
	if err != nil {
		return Manifest{}, err
	}
	defer f.Close()
	var manifest Manifest
	if err := json.NewDecoder(f).Decode(&manifest); err != nil {
		return Manifest{}, err
	}
	return manifest, nil
}

func executeCase(kind string, opts runOptions, manifest Manifest, tc Case, stderr io.Writer) (bool, string) {
	argv := nativeCommand(kind, opts, manifest, tc)
	if len(argv) == 0 {
		return false, "adapter kind has no native command"
	}
	var out, errOut bytes.Buffer
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Stdout = &out
	cmd.Stderr = &errOut
	err := cmd.Run()
	if errOut.Len() > 0 {
		_, _ = stderr.Write(errOut.Bytes())
	}
	if err != nil {
		message := strings.TrimSpace(out.String() + "\n" + errOut.String())
		if message == "" {
			message = err.Error()
		}
		return false, message
	}
	return true, ""
}

func nativeCommand(kind string, opts runOptions, manifest Manifest, tc Case) []string {
	name := caseName(tc)
	source := caseSource(tc)
	switch kind {
	case KindNodeTest:
		argv := []string{defaultString(opts.nodeBin, "node"), "--test"}
		if opts.testReporter != "" {
			argv = append(argv, "--test-reporter", opts.testReporter)
		}
		if name != "" {
			argv = append(argv, "--test-name-pattern", "^"+regexp.QuoteMeta(name)+"$")
		}
		if source != "" {
			argv = append(argv, source)
		}
		return argv
	case KindGoTest:
		pkg := defaultString(source, ".")
		argv := []string{defaultString(opts.goBin, "go"), "test", pkg}
		if name != "" {
			argv = append(argv, "-run", "^"+regexp.QuoteMeta(name)+"$")
		}
		if opts.count != "" {
			argv = append(argv, "-count", opts.count)
		}
		return argv
	case KindVitest:
		argv := []string{"npx", "vitest", "run"}
		if opts.config != "" {
			argv = append(argv, "--config", opts.config)
		}
		if name != "" {
			argv = append(argv, "--testNamePattern", name)
		}
		if opts.pool != "" {
			argv = append(argv, "--pool", opts.pool)
		}
		if opts.updateSnapshots {
			argv = append(argv, "--update")
		}
		if source != "" {
			argv = append(argv, source)
		}
		return argv
	case KindPlaywright:
		argv := []string{"npx", "playwright", "test"}
		if opts.config != "" {
			argv = append(argv, "--config", opts.config)
		}
		for _, project := range opts.projects {
			argv = append(argv, "--project", project)
		}
		if opts.workers != "" {
			argv = append(argv, "--workers", opts.workers)
		}
		if opts.updateSnapshots {
			argv = append(argv, "--update-snapshots")
		}
		if name != "" {
			argv = append(argv, "--grep", name)
		}
		if source != "" {
			argv = append(argv, source)
		}
		return argv
	case KindMoonTest:
		argv := []string{defaultString(opts.moonBin, "moon"), "test"}
		if source != "" {
			argv = append(argv, source)
		}
		if opts.target != "" {
			argv = append(argv, "--target", opts.target)
		}
		if opts.update {
			argv = append(argv, "--update")
		}
		return argv
	default:
		return nil
	}
}

func caseName(tc Case) string {
	if tc.Name != nil && *tc.Name != "" {
		return *tc.Name
	}
	if tc.Selector != nil {
		if name := tc.Selector["name"]; name != "" {
			return name
		}
	}
	if i := strings.LastIndex(tc.ID, "::"); i >= 0 && i+2 < len(tc.ID) {
		return tc.ID[i+2:]
	}
	return tc.ID
}

func caseSource(tc Case) string {
	if tc.SourceModule != nil && *tc.SourceModule != "" {
		return *tc.SourceModule
	}
	if tc.Selector != nil {
		if path := tc.Selector["path"]; path != "" {
			return path
		}
		if pkg := tc.Selector["package"]; pkg != "" {
			return pkg
		}
	}
	if i := strings.LastIndex(tc.ID, "::"); i > 0 {
		return tc.ID[:i]
	}
	return ""
}

func runCoverage(kind string, args []string, stdout io.Writer) error {
	fs := flag.NewFlagSet("coverage", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	coverprofile := fs.String("coverprofile", "", "coverage profile")
	if err := fs.Parse(args); err != nil {
		return err
	}
	metrics := []map[string]any{}
	if kind == KindGoTest && *coverprofile != "" {
		covered, total, err := parseGoCoverProfile(*coverprofile)
		if err != nil {
			return err
		}
		metrics = append(metrics, map[string]any{"name": "statements", "covered": covered, "total": total})
	}
	return json.NewEncoder(stdout).Encode(map[string][]map[string]any{"metrics": metrics})
}

func parseGoCoverProfile(path string) (int, int, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0, 0, err
	}
	covered, total := 0, 0
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "mode:") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}
		total++
		if fields[2] != "0" {
			covered++
		}
	}
	return covered, total, nil
}

type jsDiscoverOptions struct {
	inputs      []string
	excludes    []string
	namePattern string
	defaultRoot string
}

func discoverJS(opts jsDiscoverOptions) ([]Case, error) {
	files, err := collectFiles(opts.inputs, isJSLikeTestFile)
	if err != nil {
		return nil, err
	}
	files = filterExcluded(files, opts.excludes)
	matches, err := compileOptionalRegexp(opts.namePattern)
	if err != nil {
		return nil, err
	}
	var cases []Case
	for _, file := range files {
		found, err := parseJSTestFile(file, matches)
		if err != nil {
			return nil, err
		}
		cases = append(cases, found...)
	}
	return cases, nil
}

var jsTestLineRE = regexp.MustCompile(`\b(?:test|it)(\.(?:skip|only|fixme))?\s*\(\s*['"` + "`" + `]([^'"` + "`" + `]+)['"` + "`" + `]`)

func parseJSTestFile(file string, namePattern *regexp.Regexp) ([]Case, error) {
	b, err := os.ReadFile(file)
	if err != nil {
		return nil, err
	}
	source := filepath.ToSlash(file)
	var cases []Case
	for _, line := range strings.Split(string(b), "\n") {
		m := jsTestLineRE.FindStringSubmatch(line)
		if len(m) == 0 {
			continue
		}
		name := m[2]
		if namePattern != nil && !namePattern.MatchString(name) {
			continue
		}
		pending := m[1] == ".skip" || m[1] == ".fixme"
		cases = append(cases, Case{
			ID:           source + "::" + name,
			Name:         stringPtr(name),
			SourceModule: stringPtr(source),
			Selector:     map[string]string{"name": name, "path": source},
			Pending:      pending,
			BatchKey:     source,
		})
	}
	return cases, nil
}

func discoverGo(goBin string, packages []string, runPattern string) ([]Case, error) {
	pattern := defaultString(runPattern, ".")
	expanded, err := expandGoPackages(goBin, packages)
	if err != nil {
		return nil, err
	}
	testNameRE := regexp.MustCompile(`^(Test|Benchmark|Fuzz|Example)[A-Za-z0-9_]*$`)
	var cases []Case
	for _, pkg := range expanded {
		cmd := exec.Command(defaultString(goBin, "go"), "test", "-list", pattern, pkg)
		var out, errOut bytes.Buffer
		cmd.Stdout = &out
		cmd.Stderr = &errOut
		if err := cmd.Run(); err != nil {
			message := strings.TrimSpace(out.String() + "\n" + errOut.String())
			if message == "" {
				message = err.Error()
			}
			return nil, errors.New(message)
		}
		for _, line := range strings.Split(out.String(), "\n") {
			line = strings.TrimSpace(line)
			if !testNameRE.MatchString(line) {
				continue
			}
			cases = append(cases, Case{
				ID:           pkg + "::" + line,
				Name:         stringPtr(line),
				SourceModule: stringPtr(pkg),
				Selector:     map[string]string{"name": line, "package": pkg},
				BatchKey:     pkg,
			})
		}
	}
	return cases, nil
}

func expandGoPackages(goBin string, packages []string) ([]string, error) {
	var expanded []string
	seen := map[string]bool{}
	for _, pkg := range packages {
		if !strings.Contains(pkg, "...") {
			if !seen[pkg] {
				expanded = append(expanded, pkg)
				seen[pkg] = true
			}
			continue
		}
		cmd := exec.Command(defaultString(goBin, "go"), "list", "-f", "{{.Dir}}", pkg)
		var out, errOut bytes.Buffer
		cmd.Stdout = &out
		cmd.Stderr = &errOut
		if err := cmd.Run(); err != nil {
			message := strings.TrimSpace(out.String() + "\n" + errOut.String())
			if message == "" {
				message = err.Error()
			}
			return nil, errors.New(message)
		}
		cwd, err := os.Getwd()
		if err != nil {
			return nil, err
		}
		for _, line := range strings.Split(out.String(), "\n") {
			dir := strings.TrimSpace(line)
			if dir == "" {
				continue
			}
			resolved := dir
			if rel, err := filepath.Rel(cwd, dir); err == nil && !strings.HasPrefix(rel, "..") {
				if rel == "." {
					resolved = "."
				} else {
					resolved = "./" + filepath.ToSlash(rel)
				}
			}
			if !seen[resolved] {
				expanded = append(expanded, resolved)
				seen[resolved] = true
			}
		}
	}
	sort.Strings(expanded)
	return expanded, nil
}

func discoverMoon(packages []string, targets []string) ([]Case, error) {
	files, err := collectFiles(packages, isMoonTestFile)
	if err != nil {
		return nil, err
	}
	var cases []Case
	for _, file := range files {
		found, err := parseMoonTestFile(file)
		if err != nil {
			return nil, err
		}
		for i := range found {
			if len(targets) > 0 {
				found[i].Tags = append(found[i].Tags, targets...)
			}
		}
		cases = append(cases, found...)
	}
	return cases, nil
}

var moonTestLineRE = regexp.MustCompile(`\btest\s+(?:"([^"]+)"|([A-Za-z0-9_./-]+))`)

func parseMoonTestFile(file string) ([]Case, error) {
	b, err := os.ReadFile(file)
	if err != nil {
		return nil, err
	}
	source := filepath.ToSlash(file)
	var cases []Case
	for _, line := range strings.Split(string(b), "\n") {
		m := moonTestLineRE.FindStringSubmatch(line)
		if len(m) == 0 {
			continue
		}
		name := m[1]
		if name == "" {
			name = m[2]
		}
		cases = append(cases, Case{
			ID:           source + "::" + name,
			Name:         stringPtr(name),
			SourceModule: stringPtr(source),
			Selector:     map[string]string{"name": name, "path": source},
			BatchKey:     source,
		})
	}
	return cases, nil
}

func collectFiles(inputs []string, accept func(string) bool) ([]string, error) {
	seen := map[string]bool{}
	var files []string
	for _, input := range inputs {
		if input == "" {
			continue
		}
		matches, err := expandInput(input, accept)
		if err != nil {
			return nil, err
		}
		for _, file := range matches {
			file = filepath.Clean(file)
			if seen[file] {
				continue
			}
			seen[file] = true
			files = append(files, file)
		}
	}
	sort.Strings(files)
	return files, nil
}

func expandInput(input string, accept func(string) bool) ([]string, error) {
	if hasMeta(input) {
		return expandGlob(input, accept)
	}
	info, err := os.Stat(input)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	if info.IsDir() {
		return walkAccepted(input, accept)
	}
	if accept(input) {
		return []string{input}, nil
	}
	return nil, nil
}

func expandGlob(pattern string, accept func(string) bool) ([]string, error) {
	root := globRoot(pattern)
	var matches []string
	if root == "" {
		root = "."
	}
	if _, err := os.Stat(root); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if shouldSkipDir(d.Name()) {
				return filepath.SkipDir
			}
			return nil
		}
		if !accept(path) {
			return nil
		}
		if globMatch(pattern, path) {
			matches = append(matches, path)
		}
		return nil
	})
	return matches, err
}

func walkAccepted(root string, accept func(string) bool) ([]string, error) {
	var files []string
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if shouldSkipDir(d.Name()) {
				return filepath.SkipDir
			}
			return nil
		}
		if accept(path) {
			files = append(files, path)
		}
		return nil
	})
	return files, err
}

func filterExcluded(files []string, excludes []string) []string {
	if len(excludes) == 0 {
		return files
	}
	var out []string
	for _, file := range files {
		excluded := false
		for _, pattern := range excludes {
			if globMatch(pattern, file) {
				excluded = true
				break
			}
		}
		if !excluded {
			out = append(out, file)
		}
	}
	return out
}

func isJSLikeTestFile(path string) bool {
	base := filepath.Base(path)
	ext := filepath.Ext(path)
	switch ext {
	case ".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".mts", ".cts":
	default:
		return false
	}
	return strings.Contains(base, ".test.") || strings.Contains(base, ".spec.")
}

func isMoonTestFile(path string) bool {
	return filepath.Ext(path) == ".mbt"
}

func shouldSkipDir(name string) bool {
	switch name {
	case ".git", "node_modules", "vendor", "dist", "build", ".next", "coverage":
		return true
	default:
		return false
	}
}

func hasMeta(pattern string) bool {
	return strings.ContainsAny(pattern, "*?[")
}

func globRoot(pattern string) string {
	cut := len(pattern)
	for _, token := range []string{"*", "?", "["} {
		if i := strings.Index(pattern, token); i >= 0 && i < cut {
			cut = i
		}
	}
	root := filepath.Dir(pattern[:cut])
	if root == "." && strings.HasPrefix(pattern, string(filepath.Separator)) {
		return string(filepath.Separator)
	}
	if root == "." || root == "" {
		return "."
	}
	return root
}

func globMatch(pattern, target string) bool {
	pattern = filepath.ToSlash(filepath.Clean(pattern))
	target = filepath.ToSlash(filepath.Clean(target))
	if ok, _ := pathpkg.Match(pattern, target); ok {
		return true
	}
	if !strings.Contains(pattern, "**/") {
		return false
	}
	parts := strings.SplitN(pattern, "**/", 2)
	prefix, suffix := parts[0], parts[1]
	if prefix != "" && !strings.HasPrefix(target, prefix) {
		return false
	}
	rest := strings.TrimPrefix(target, prefix)
	if ok, _ := pathpkg.Match(suffix, rest); ok {
		return true
	}
	if ok, _ := pathpkg.Match(suffix, pathpkg.Base(rest)); ok {
		return true
	}
	return false
}

func compileOptionalRegexp(pattern string) (*regexp.Regexp, error) {
	if pattern == "" {
		return nil, nil
	}
	return regexp.Compile(pattern)
}

func sortCases(cases []Case) {
	sort.Slice(cases, func(i, j int) bool {
		return cases[i].ID < cases[j].ID
	})
}

func defaultString(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}

func defaultStrings(values []string, fallback []string) []string {
	if len(values) == 0 {
		return fallback
	}
	return values
}

func stringPtr(value string) *string {
	return &value
}

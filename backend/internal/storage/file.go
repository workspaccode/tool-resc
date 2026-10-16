package storage

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"sync"

	"toolsresc/backend/internal/state"
)

// File is an append-only JSON Lines log: one event per line, synced to disk
// before Append returns.
type File struct {
	mu sync.Mutex
	f  *os.File
}

// OpenFile opens or creates the log, creating its folder if needed.
func OpenFile(path string) (*File, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	// Not O_APPEND: Windows can't truncate a torn tail through an append
	// handle. Append seeks to the end itself, under the lock.
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, err
	}
	return &File{f: f}, nil
}

func (l *File) Append(_ context.Context, env state.Envelope) error {
	line, err := json.Marshal(env)
	if err != nil {
		return err
	}
	line = append(line, '\n')

	l.mu.Lock()
	defer l.mu.Unlock()
	if _, err := l.f.Seek(0, io.SeekEnd); err != nil {
		return err
	}
	if _, err := l.f.Write(line); err != nil {
		return err
	}
	return l.f.Sync()
}

// Replay reads every event. A last line without a newline is a write cut
// short by a crash: it is dropped and the file truncated to the last whole
// event. Any other bad line is an error, so data is never silently lost.
func (l *File) Replay(ctx context.Context, fn func(state.Envelope) error) error {
	l.mu.Lock()
	defer l.mu.Unlock()

	if _, err := l.f.Seek(0, io.SeekStart); err != nil {
		return err
	}
	r := bufio.NewReaderSize(l.f, 1<<20)
	var good int64
	for n := 1; ; n++ {
		if err := ctx.Err(); err != nil {
			return err
		}
		line, err := r.ReadBytes('\n')
		if errors.Is(err, io.EOF) {
			if len(bytes.TrimSpace(line)) > 0 {
				slog.Warn("event log: dropping incomplete last line", "line", n, "bytes", len(line))
				return l.f.Truncate(good)
			}
			return nil
		}
		if err != nil {
			return err
		}
		good += int64(len(line))
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		var env state.Envelope
		if err := json.Unmarshal(line, &env); err != nil {
			return fmt.Errorf("line %d: %w", n, err)
		}
		if err := fn(env); err != nil {
			return err
		}
	}
}

func (l *File) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.f.Close()
}

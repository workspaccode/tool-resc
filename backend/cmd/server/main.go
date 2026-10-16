// Command server runs the ToolsResc sync backend: devices (no accounts)
// share projects by code, sync the projects' lists, and record scans that
// are counted by part, list, device and more.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
	_ "time/tzdata" // ?tz= works on hosts without a zoneinfo database

	"toolsresc/backend/internal/config"
	"toolsresc/backend/internal/state"
	"toolsresc/backend/internal/storage"
	"toolsresc/backend/internal/transport/httpapi"
	"toolsresc/backend/internal/usecase"
)

func main() {
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, nil)))
	if err := run(); err != nil {
		slog.Error("server stopped", "err", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// Composition root: storage -> state -> use cases -> transport.
	var log state.EventLog
	if cfg.DataFile == "memory" {
		log = storage.NewMemory()
	} else if log, err = storage.OpenFile(cfg.DataFile); err != nil {
		return err
	}
	start := time.Now()
	store, err := state.Open(ctx, log)
	if err != nil {
		log.Close()
		return err
	}
	defer store.Close()

	var events uint64
	store.View(func(s *state.State) { events = s.Seq })
	slog.Info("state loaded", "events", events, "data", cfg.DataFile, "ms", time.Since(start).Milliseconds())

	svc := httpapi.Services{
		Devices:  usecase.NewDevices(store, time.Now),
		Projects: usecase.NewProjects(store, time.Now),
		Lists:    usecase.NewLists(store, time.Now),
		Scans:    usecase.NewScans(store, time.Now),
		Stats:    usecase.NewStats(store),
	}
	srv := &http.Server{
		Addr: cfg.Addr,
		Handler: httpapi.NewRouter(svc, httpapi.Options{
			APIKey:       cfg.APIKey,
			MaxBodyBytes: int64(cfg.MaxBodyMB) << 20,
			AllowOrigin:  cfg.AllowOrigin,
		}),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       2 * time.Minute, // big imports from slow phones
		WriteTimeout:      2 * time.Minute,
		IdleTimeout:       2 * time.Minute,
	}

	errc := make(chan error, 1)
	go func() {
		slog.Info("listening", "addr", cfg.Addr, "auth", cfg.APIKey != "")
		errc <- srv.ListenAndServe()
	}()

	select {
	case err := <-errc:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	case <-ctx.Done():
		slog.Info("shutting down")
	}
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	return srv.Shutdown(shutdownCtx)
}

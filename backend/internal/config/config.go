// Package config reads the server settings from the environment.
package config

import (
	"fmt"
	"os"
	"strconv"
)

type Config struct {
	// Addr to listen on. TOOLSRESC_ADDR, default ":8080".
	Addr string
	// DataFile is the event log. TOOLSRESC_DATA, default "data/events.jsonl".
	// "memory" keeps everything in memory (lost on restart).
	DataFile string
	// APIKey the app must send. TOOLSRESC_API_KEY, default none (open).
	APIKey string
	// MaxBodyMB limits request bodies. TOOLSRESC_MAX_BODY_MB, default 64.
	MaxBodyMB int
	// AllowOrigin enables CORS. TOOLSRESC_CORS_ORIGIN, default off.
	AllowOrigin string
}

func Load() (Config, error) {
	c := Config{
		Addr:        env("TOOLSRESC_ADDR", ":8080"),
		DataFile:    env("TOOLSRESC_DATA", "data/events.jsonl"),
		APIKey:      os.Getenv("TOOLSRESC_API_KEY"),
		AllowOrigin: os.Getenv("TOOLSRESC_CORS_ORIGIN"),
		MaxBodyMB:   64,
	}
	if v := os.Getenv("TOOLSRESC_MAX_BODY_MB"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 {
			return c, fmt.Errorf("TOOLSRESC_MAX_BODY_MB: want a positive number, got %q", v)
		}
		c.MaxBodyMB = n
	}
	return c, nil
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

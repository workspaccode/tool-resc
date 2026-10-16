package httpapi

import (
	"context"
	"crypto/subtle"
	"log/slog"
	"net/http"
	"runtime/debug"
	"strings"
	"time"

	"toolsresc/backend/internal/domain"
)

// Middleware wraps a handler (decorator pattern).
type Middleware func(http.Handler) http.Handler

// Chain applies middleware so the first one listed runs first.
func Chain(h http.Handler, mw ...Middleware) http.Handler {
	for i := len(mw) - 1; i >= 0; i-- {
		h = mw[i](h)
	}
	return h
}

// Recover turns a panic into a 500 instead of a dropped connection.
func Recover(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if v := recover(); v != nil {
				slog.Error("panic", "path", r.URL.Path, "value", v, "stack", string(debug.Stack()))
				writeJSON(w, http.StatusInternalServerError, errorBody{"internal error"})
			}
		}()
		next.ServeHTTP(w, r)
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

// Log writes one line per request.
func Log(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		slog.Info("http", "method", r.Method, "path", r.URL.Path, "status", rec.status,
			"ms", time.Since(start).Milliseconds())
	})
}

// CORS allows a browser dashboard on another origin. Empty origin: off.
func CORS(origin string) Middleware {
	return func(next http.Handler) http.Handler {
		if origin == "" {
			return next
		}
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			h := w.Header()
			h.Set("Access-Control-Allow-Origin", origin)
			h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-API-Key, X-Device-Id")
			h.Set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
			if r.Method == http.MethodOptions {
				w.WriteHeader(http.StatusNoContent)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// APIKey requires `Authorization: Bearer <key>` or `X-API-Key: <key>`.
// An empty key turns the check off (for a server on a trusted network).
func APIKey(key string) Middleware {
	return func(next http.Handler) http.Handler {
		if key == "" {
			return next
		}
		want := []byte(key)
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			got := r.Header.Get("X-API-Key")
			if got == "" {
				got = strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
			}
			if subtle.ConstantTimeCompare([]byte(got), want) != 1 {
				writeJSON(w, http.StatusUnauthorized, errorBody{"missing or wrong API key"})
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// MaxBody limits request bodies.
func MaxBody(n int64) Middleware {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			r.Body = http.MaxBytesReader(w, r.Body, n)
			next.ServeHTTP(w, r)
		})
	}
}

type ctxKey struct{}

// RequireDevice reads the device id from X-Device-Id into the context.
func RequireDevice(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimSpace(r.Header.Get("X-Device-Id"))
		if err := domain.ValidDeviceID(id); err != nil {
			writeJSON(w, http.StatusBadRequest, errorBody{"X-Device-Id: " + err.Error()})
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), ctxKey{}, id)))
	})
}

// deviceID is the id RequireDevice stored.
func deviceID(r *http.Request) string {
	id, _ := r.Context().Value(ctxKey{}).(string)
	return id
}

package httpapi

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"

	"toolsresc/backend/internal/domain"
)

type errorBody struct {
	Error string `json:"error"`
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		slog.Warn("write response", "err", err)
	}
}

// writeError maps domain errors to status codes; anything unexpected is a
// 500 whose details stay in the log.
func writeError(w http.ResponseWriter, r *http.Request, err error) {
	var tooBig *http.MaxBytesError
	switch {
	case errors.Is(err, domain.ErrInvalid):
		writeJSON(w, http.StatusBadRequest, errorBody{err.Error()})
	case errors.Is(err, domain.ErrNotFound):
		writeJSON(w, http.StatusNotFound, errorBody{"not found"})
	case errors.Is(err, domain.ErrTooManyAttempts):
		writeJSON(w, http.StatusTooManyRequests, errorBody{err.Error()})
	case errors.As(err, &tooBig):
		writeJSON(w, http.StatusRequestEntityTooLarge, errorBody{"request body too large"})
	default:
		slog.Error("request failed", "method", r.Method, "path", r.URL.Path, "err", err)
		writeJSON(w, http.StatusInternalServerError, errorBody{"internal error"})
	}
}

// decode reads a JSON body. Unknown fields are allowed so older servers
// accept newer apps.
func decode(r *http.Request, v any) error {
	if err := json.NewDecoder(r.Body).Decode(v); err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			return err
		}
		return domain.Invalid("bad JSON: %v", err)
	}
	return nil
}

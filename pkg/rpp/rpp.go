// Package rpp defines helpers for using the RPPv0 (Reginald plugin protocol
// version 0) in Go programs.
package rpp

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"strconv"
	"strings"
)

// Constant values related to the RPP version currently implemented by this
// package.
const (
	ContentType    = "application/json-rpc" // default content type of messages
	JSONRCPVersion = "2.0"                  // JSON-RCP version the protocol uses
	Name           = "rpp"                  // protocol name to use in handshake
	Version        = 0                      // protocol version
)

// Standard method names used by the RPP.
const (
	MethodExit       = "exit"
	MethodHandshake  = "handshake"
	MethodInitialize = "initialize"
	MethodLog        = "log"
	MethodRunPrefix  = "run/" // full method name will have the called command after this prefix
	MethodShutdown   = "shutdown"
)

// Error codes used for the protocol.
const (
	ParseError     = -32700
	InvalidRequest = -32600
	MethodNotFound = -32601
	InvalidParams  = -32602
	InternalError  = -32603
)

// The different type values for flags defined by the plugins.
const (
	FlagBool   FlagType = "bool"
	FlagInt    FlagType = "int"
	FlagString FlagType = "string"
)

// Errors returned by the RPP helper functions.
var (
	errZeroLength = errors.New("content-length is zero")
)

// FlagType is used as the type of the fields that define the type of a flag in
// a command.
type FlagType string

// A Message is the Go representation of a message using RPP. It includes all of
// the possible fields for a message. Thus, the values that are not used for a
// particular type of a message are omitted and the fields must be validated by
// the client and the server.
type Message struct {
	// JSONRCP is the JSON-RCP version used by the protocol and the message.
	// This must be exactly "2.0" or the client will reject the message.
	JSONRCP string `json:"jsonrpc"`

	// ID is the identifier established by the client and it must be included
	// for all messages except notification. It must be either an integer or
	// a string, and setting this field to nil is reserved for notifications and
	// special error cases as described by the protocols in use.
	ID any `json:"id,omitempty"`

	// Method is the name of the method to be invoked on the server. It must be
	// present in all of the requests and notifications that the client sends.
	Method string `json:"method,omitempty"`

	// Params are the parameters that are send with a method call. They are
	// encoded in this type as a raw JSON value as in the provided functions
	// the helpers used for reading the incoming messages handle the rest of
	// the fields and the plugin implementation must take care of the method
	// functionality according to the called method and the parameters.
	Params json.RawMessage `json:"params,omitempty"`

	// Result is the result of a method call as a raw JSON value. It must only
	// be present when the method call succeeded. Handling of the result is
	// similar to the handling of Params.
	Result json.RawMessage `json:"result,omitempty"`

	// Error is the error triggered by the invoked method, the error caused by
	// an invalid message etc. It must not be present on success. Handling of
	// the error is similar to the handling of Params.
	Error json.RawMessage `json:"error,omitempty"`
}

// An Error is the Go representation of a JSON-RCP error object using RPP.
type Error struct {
	// Code is the error code that tells the error type. See the constant error
	// codes for the different supported values.
	Code int `json:"code"`

	// Message is the error message.
	Message string `json:"message"`

	// Data contains optional additional information about the error.
	Data any `json:"data,omitempty"`
}

// Handshake is a helper type that contains the handshake information fields
// that are shared between the "handshake" method parameters and the response.
// These values must match in order to perform the handshake successfully.
// The valid values for the current implementation are provided as constants in
// this package.
type Handshake struct {
	// Protocol is the identifier of the protocol to use. It must be "rpp" for
	// the handshake to succeed.
	Protocol string `json:"protocol"`

	// ProtocolVersion is the version of the protocol to use. It must be 0 for
	// the handshake to succeed.
	ProtocolVersion int `json:"protocolVersion"`
}

// HandshakeParams are the parameters that the client passes when calling the
// "handshake" method on the server.
type HandshakeParams struct {
	Handshake
}

// HandshakeResult is the result struct the server returns when the handshake
// method is successful.
type HandshakeResult struct {
	Handshake

	// Name is the user-friendly name of the plugin that will be used in
	// the logs and in the user output. It must be unique and loading
	// the plugins will fail if two or more plugins have exactly the same name.
	Name string `json:"name"`

	// Commands contains the information on the command types this plugin
	// offers. If the plugin does not provide any commands, this can be either
	// nil or an empty list.
	Commands []CommandInfo `json:"commands,omitempty"`

	// Tasks contains the information on the task types this plugin offers. It
	// is a list of the provided task types. If the plugin does not provide any
	// tasks, this can be either nil or an empty list.
	Tasks []TaskInfo `json:"tasks:omitempty"`
}

// CommandInfo contains information on a command that a plugin implements.
// CommandInfo is only used for discovering the plugin capabilities, and
// the actual command functionality is not implemented within this type.
type CommandInfo struct {
	// Name is the name of the command as it should be written by the user when
	// they run the command. It must not match any existing commands either
	// within Reginald or other plugins.
	Name string `json:"name"`

	// UsageLine is the one-line usage synopsis of the command.
	UsageLine string `json:"usage"`

	// Flags contains the information on the command-line flags that this
	// command provides.
	Flags []Flag `json:"flags,omitempty"`
}

// TaskInfo contains information on a task that a plugin implements. TaskInfo is
// only used for discovering the plugin capabilities, and the actual task
// functionality is not implemented within this type.
type TaskInfo struct {
	// Name is the name of the task type as it should be written by the user
	// when they specify it in, for example, their configuration. It must not
	// match any existing tasks either within Reginald or other plugins.
	Name string `json:"name"`
}

// Flag is an entry in the handshake response for a command that defines one
// flag. The type of the flag is inferred using the type of the default value.
type Flag struct {
	// Name is the full name of the flag, used in the form of "--example". This
	// must be unique across Reginald and all of the flags currently in use by
	// the commands.
	Name string `json:"name"`
	// Shorthand is the short one-letter name of the flag, used in the form of
	// "-e". This must be unique across Reginald and all of the flags currently
	// in use by the commands.
	Shorthand string `json:"shorthand,omitempty"`

	// DefaultValue is the default value of the flag as the type it should be
	// defined as.
	DefaultValue any `json:"defaultValue"`

	// Type is a string representation of the type of the value that this flag
	// holds. The possible values can be found in the protocol description and
	// in the constants of this package.
	Type FlagType `json:"type"`

	// Usage is the help description of this flag.
	Usage string `json:"usage"`
}

// LogParams are the parameters passed with the "log" method. Reginald uses
// structured logging where the given message is one field of the log output and
// additional information can be given as Fields.
type LogParams struct {
	// Level is the logging level of the message. It should have a string value "debug", "info", "warn", or "error".
	Level slog.Level `json:"level"`

	// Message is the logging message.
	Message string `json:"msg"`

	// Fields contains additional fields that should be included with the
	// message. Reginald automatically adds information about the plugin from
	// which the message came from.
	Fields map[string]any `json:"fields,omitempty"`
}

// RunParams are the parameters passed when the client runs a command from
// a plugin.
type RunParams struct {
	// Args are the command-line arguments after parsing the commands and flags.
	// It should contain the positional arguments required by the command.
	Args []string `json:"args"`
}

// Error returns the string representation of the error e.
func (e *Error) Error() string {
	if e.Data != nil {
		return fmt.Sprintf("%s (%v)", e.Message, e.Data)
	}

	return e.Message
}

// DefaultHandshakeParams returns the default parameters used by the client in
// the handshake method call.
func DefaultHandshakeParams() HandshakeParams {
	return HandshakeParams{
		Handshake: Handshake{
			Protocol:        Name,
			ProtocolVersion: Version,
		},
	}
}

// Read reads one message from r.
func Read(r *bufio.Reader) (*Message, error) {
	var l int

	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return nil, fmt.Errorf("failed to read line: %w", err)
		}

		line = strings.TrimRight(line, "\r\n")
		if line == "" {
			break
		}

		// TODO: Disallow other headers.
		if strings.HasPrefix(strings.ToLower(line), "content-length:") {
			v := strings.TrimSpace(line[strings.IndexByte(line, ':')+1:])

			if l, err = strconv.Atoi(v); err != nil {
				return nil, fmt.Errorf("bad Content-Length %q: %w", v, err)
			}
		}
	}

	if l <= 0 {
		return nil, fmt.Errorf("%w", errZeroLength)
	}

	buf := make([]byte, l)
	if _, err := io.ReadFull(r, buf); err != nil {
		return nil, fmt.Errorf("failed to read message: %w", err)
	}

	var msg Message

	// TODO: Disallow unknown fields.
	if err := json.Unmarshal(buf, &msg); err != nil {
		return nil, fmt.Errorf("failed to decode message from JSON: %w", err)
	}

	return &msg, nil
}

// Write writes an RPP message to the given writer.
func Write(w io.Writer, msg *Message) error {
	// TODO: Disallow unknown fields.
	data, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("failed to marshal RPP message: %w", err)
	}

	header := fmt.Sprintf("Content-Length: %d\r\n\r\n", len(data))
	if _, err = w.Write([]byte(header)); err != nil {
		return fmt.Errorf("failed to write message header: %w", err)
	}

	if _, err = w.Write(data); err != nil {
		return fmt.Errorf("failed to write message: %w", err)
	}

	return nil
}

// LogValue implements [slog.LogValuer] for message. It returns a group
// containing the fields of the Message, so that they appear together in the log
// output.
func (m *Message) LogValue() slog.Value {
	var attrs []slog.Attr

	attrs = append(attrs, slog.String("jsonrcp", m.JSONRCP))

	if m.ID != nil {
		attrs = append(attrs, slog.Attr{Key: "id", Value: IDLogValue(m.ID)})
	}

	attrs = append(attrs, slog.String("method", m.Method))

	if m.Params != nil {
		attrs = append(attrs, slog.String("params", string(m.Params)))
	}

	if m.Result != nil {
		attrs = append(attrs, slog.String("result", string(m.Result)))
	}

	if m.Error != nil {
		attrs = append(attrs, slog.String("error", string(m.Error)))
	}

	return slog.GroupValue(attrs...)
}

// IDLogValue return the [slog.Value] for the given message ID.
func IDLogValue(id any) slog.Value {
	// TODO: Find a safer way to convert the number types.
	switch v := id.(type) {
	case float64:
		u := int64(v)
		if float64(u) != v {
			return slog.StringValue(fmt.Sprintf("invalid ID type %T", v))
		}

		return slog.Int64Value(u)
	case string:
		return slog.StringValue(v)
	case *int:
		return slog.IntValue(*v)
	case *int64:
		return slog.Int64Value(*v)
	case *float64:
		u := int64(*v)
		if float64(u) != *v {
			return slog.StringValue(fmt.Sprintf("invalid ID type %T", v))
		}

		return slog.Int64Value(u)
	case *string:
		return slog.StringValue(*v)
	default:
		return slog.StringValue(fmt.Sprintf("invalid ID type %T", v))
	}
}

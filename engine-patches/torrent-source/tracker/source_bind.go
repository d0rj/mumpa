package tracker

import (
	"context"
	"errors"
	"net"
	"strings"
	"time"
)

func (me Announce) hasSourceBinding() bool {
	return me.SourceIP != nil && !me.SourceIP.IsUnspecified()
}

func (me Announce) validateSourceBinding() error {
	if !me.hasSourceBinding() {
		return nil
	}
	if me.SourceIP.To16() == nil {
		return errors.New("invalid tracker source IP")
	}
	if me.HTTPProxy != nil {
		return errors.New("proxy and explicit tracker source binding cannot be combined")
	}
	return nil
}

func (me Announce) dialBound(ctx context.Context, network, address string) (net.Conn, error) {
	if err := me.validateSourceBinding(); err != nil {
		return nil, err
	}
	dialer := net.Dialer{Timeout: 15 * time.Second}
	if me.hasSourceBinding() {
		family := "6"
		if me.SourceIP.To4() != nil {
			family = "4"
		}
		if (strings.HasSuffix(network, "4") || strings.HasSuffix(network, "6")) &&
			!strings.HasSuffix(network, family) {
			return nil, errors.New("tracker source does not match destination network family")
		}
		if strings.HasPrefix(network, "tcp") {
			network = "tcp" + family
			dialer.LocalAddr = &net.TCPAddr{IP: me.SourceIP}
		} else if strings.HasPrefix(network, "udp") {
			network = "udp" + family
			dialer.LocalAddr = &net.UDPAddr{IP: me.SourceIP}
		} else {
			return nil, errors.New("unsupported tracker source network")
		}
	}
	return dialer.DialContext(ctx, network, address)
}

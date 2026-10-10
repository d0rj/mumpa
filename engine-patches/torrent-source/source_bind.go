package torrent

import (
	"errors"
	"net"
	"strings"
)

// outgoingSourceIP is a local socket address, never a public announce override.
// Do not resolve a hostname or silently switch to an unbound source on failure.
func outgoingSourceIP(cfg *ClientConfig, network string) (net.IP, error) {
	if cfg.ListenHost == nil {
		return nil, errors.New("missing listen host function")
	}
	host := cfg.ListenHost(network)
	if host == "" {
		return nil, nil
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return nil, errors.New("source binding requires a literal listen IP")
	}
	if ip.IsUnspecified() {
		return nil, nil
	}
	if (strings.HasSuffix(network, "4") && ip.To4() == nil) ||
		(strings.HasSuffix(network, "6") && ip.To4() != nil) {
		return nil, errors.New("source IP does not match the enabled network family")
	}
	return ip, nil
}

func validateSourceBinding(cfg *ClientConfig, networks []network) error {
	for _, network := range networks {
		ip, err := outgoingSourceIP(cfg, network.String())
		if err != nil {
			return err
		}
		if ip != nil && (cfg.ProxyURL != "" || cfg.HTTPProxy != nil) {
			return errors.New("proxy and explicit source binding cannot be combined")
		}
	}
	return nil
}

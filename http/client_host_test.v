module http

fn test_host_header_ipv4_keeps_ephemeral_port() {
	assert host_header_value('127.0.0.1:8080') == '127.0.0.1:8080'
	assert host_header_value('127.0.0.1:80') == '127.0.0.1'
}

fn test_host_header_hostname() {
	assert host_header_value('example.com:8080') == 'example.com:8080'
	assert host_header_value('example.com:443') == 'example.com'
}

fn test_host_header_ipv6_brackets() {
	assert host_header_value('[::1]:8080') == '[::1]:8080'
	assert host_header_value('[::1]:80') == '[::1]'
	wire := serialize_request(Request{
		method:  'GET'
		target:  '/'
		path:    '/'
		version: 'HTTP/1.1'
	}, '[::1]:8080')
	assert wire.bytestr().contains('Host: [::1]:8080')
}

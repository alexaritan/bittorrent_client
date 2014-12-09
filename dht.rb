require 'bencode'
require 'digest/sha1'
require 'uri'
require 'net/http'
require 'ipaddr'

puts "Connecting to distributed hash table."

node_id = "37914862501111111211"
@nodes_to_visit = []
@nodes_visited = []
@node_offset_on_failure = 0

#When dealing with magnet links, you'll be given the info hash.
#You won't have to calculate it like you are doing below.
#This is only for testing.
file = BEncode.load_file("ubuntu-14.10-desktop-amd64.iso.torrent")
info = file["info"]
info_hash = Digest::SHA1.new.digest(info.bencode)

uri_addr = URI("router.bittorrent.com")
uri_port = 6881

while true do
	#Connect to DHT node.
	dht_udp_socket = UDPSocket.new
	dht_udp_socket.connect("#{uri_addr}", uri_port)
	puts "Connected to node #{uri_addr} #{uri_port}."

	#Send get_peers to node.
	params = {
		t: "aa",
		y: "q",
		q: "get_peers",
		a: {
			id: node_id,
			info_hash: info_hash
		}
	}
	get_peers_query = params.bencode
	dht_udp_socket.send(get_peers_query, 0)

	#Receive the get_peers response from node.
	begin
		Timeout::timeout(5){
			@nodes_visited[@nodes_visited.length] = [uri_addr, uri_port]
			@dht_get_peers_response = BEncode.load(dht_udp_socket.recv(1024))
			@node_offset_on_failure = 0
		}
	rescue
		@node_offset_on_failure += 1
		if !@nodes_to_visit.empty? && @node_offset_on_failure < @nodes_to_visit.length
			uri_addr = URI(@nodes_to_visit[@node_offset_on_failure][0])
			uri_port = @nodes_to_visit[@node_offset_on_failure][1]
			puts "Trying different node."
			next
		else
			abort("Sorry, no alternative nodes available.")
		end
	end

	#Check if values have been received instead of nodes.
	break if @dht_get_peers_response["r"]["values"] != nil

	#If values have not been received and nodes have...
	i=0
	@nodes_to_visit = [] if @dht_get_peers_response["r"]["nodes"] != nil
	while (i*26)+25<@dht_get_peers_response["r"]["nodes"].bytes.to_a.length do
		#Parse each node ip and port from response.
		dht_get_peers_id = @dht_get_peers_response["r"]["nodes"].bytes.to_a[(26*i)..((26*i)+19)]
		dht_get_peers_ip = @dht_get_peers_response["r"]["nodes"].bytes.to_a[((26*i)+20)..((26*i)+23)].join(".")
		dht_get_peers_port_a = @dht_get_peers_response["r"]["nodes"].bytes.to_a[(26*i)+24]
		dht_get_peers_port = (dht_get_peers_port_a << 8) |  @dht_get_peers_response["r"]["nodes"].bytes.to_a[(26*i)+25]

		#Add each node to @nodes_to_visit as long as it is not already in @nodes_visited.
		@nodes_to_visit[@nodes_to_visit.length] = [dht_get_peers_ip, dht_get_peers_port] if !@nodes_visited.include?([dht_get_peers_ip, dht_get_peers_port]) && dht_get_peers_ip != "127.0.0.1"
		i += 1
	end

	#Find the first node that hasn't been visited yet, then ask it for more nodes.
	@nodes_to_visit.each do |node|
		if !@nodes_visited.include?(node[0,1])
			uri_addr = URI(node[0])
			uri_port = node[1]
			break
		end
	end
	dht_udp_socket.close
end

#Parse the values from the response if they are included.
#These IPs and ports correspond to peers that are in the swarm you're looking for.
dht_get_peers_values = @dht_get_peers_response["r"]["values"] if @dht_get_peers_response["r"]["values"] != nil
if dht_get_peers_values != nil
	dht_peer = dht_get_peers_values[0].to_s.unpack("Nn")
	puts dht_peer_ip = [dht_peer[0]].pack("N").unpack("C4").join(".")
	puts dht_peer_port = dht_peer[1]

	########
	my_peer_id = "12345439123454321230"
	handshake = "\x13BitTorrent protocol\x00\x00\x00\x00\x00\x00\x00\x00#{info_hash}#{my_peer_id}"
	@connection = TCPSocket.new(IPAddr.new(dht_peer_ip).to_s, dht_peer_port)
	@connection.write(handshake)
	puts "Sent handshake"
	received_pstrlen = @connection.getbyte
	peer_response = {
		received_pstrlen: received_pstrlen,
		received_pstr: @connection.read(received_pstrlen),
		received_reserved: @connection.read(8),
		received_info_hash: @connection.read(20),
		received_peer_id: @connection.read(20)
	}
	puts "Received handshake"
	######
end

#This might help:
#https://github.com/deoxxa/bittorrent-dht-byo/blob/master/lib/dht.js
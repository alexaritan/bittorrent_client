require 'bencode'
require 'digest/sha1'
require 'uri'
require 'socket'

puts "Connecting to distributed hash table."

node_id = "37914862501111111211"

#When dealing with magnet links, you'll be given the info hash.
#You won't have to calculate it like you are doing below.
#This is only for testing.
file = BEncode.load_file("ubuntu-14.10-desktop-amd64.iso.torrent")
info = file["info"]
info_hash = Digest::SHA1.new.digest(info.bencode)

uri_addr = URI("router.bittorrent.com")
uri_port = 6881

while true do
	#Bootstrap into DHT.
	#Connect to DHT node.
	dht_udp_socket = UDPSocket.new
	dht_udp_socket.connect("#{uri_addr}", uri_port)
	puts "Connected to peer #{uri_addr} #{uri_port}."

=begin
	#Ping the DHT node.
	params = {
		t: "0",
		y: "q",
		q: "ping",
		a: {
			id: node_id
		}
	}
	ping_query = params.bencode
	dht_udp_socket.send(ping_query, 0)
	dht_ping_response = dht_udp_socket.recv(1024)
	dht_ping_response = BEncode.load(dht_ping_response)
	response_node_id = dht_ping_response["r"]["id"].unpack("H20")
=end

	#Send get_peers to bootstrap node.
	params = {
		t: "0",
		y: "q",
		q: "get_peers",
		a: {
			id: node_id,
			info_hash: info_hash
		}
	}
	get_peers_query = params.bencode
	dht_udp_socket.send(get_peers_query, 0)

	#Receive the get_peers response from bootstrap node.
	puts @dht_get_peers_response = BEncode.load(dht_udp_socket.recv(1024))

	#Parse the closer nodes from the response if they are included in the response.
	#TODO make this a loop until you get a VALUES key instead of a NODES key.
	dht_get_peers_nodes = @dht_get_peers_response["r"]["nodes"].unpack("NnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNn") if @dht_get_peers_response["r"]["nodes"] != nil
	if dht_get_peers_nodes != nil
		unpacked_get_peers_nodes = []
		i = 0
		while i<dht_get_peers_nodes.length && dht_get_peers_nodes[i] != nil do
			if i%2 == 0
				unpacked_get_peers_nodes[unpacked_get_peers_nodes.length] = []
				unpacked_get_peers_nodes[unpacked_get_peers_nodes.length - 1][0] = [dht_get_peers_nodes[i].to_i].pack("N").unpack("C4").join(".")
				unpacked_get_peers_nodes[unpacked_get_peers_nodes.length - 1][1] = dht_get_peers_nodes[i+1]
			end
			i += 1
		end
	end
	break if @dht_get_peers_response["r"]["values"] != nil
	uri_addr = URI(unpacked_get_peers_nodes[0][0])
	uri_port = unpacked_get_peers_nodes[0][1]
	#TODO now do something with unpacked_get_peers_nodes...
	dht_udp_socket.close
end

#Parse the values from the response if they are included in the response.
#These IPs and ports correspond to peers that are in the swarm you're looking for.
dht_get_peers_values = @dht_get_peers_response["r"]["values"].unpack("NnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNn") if dht_get_peers_response["r"]["values"] != nil
if dht_get_peers_values != nil
	unpacked_get_peers_values = []
	i = 0
	while i<dht_get_peers_values.length && dht_get_peers_values[i] != nil do
		if i%2 == 0
			unpacked_get_peers_values[unpacked_get_peers_values.length] = []
			unpacked_get_peers_values[unpacked_get_peers_values.length - 1][0] = [dht_get_peers_values[i].to_i].pack("N").unpack("C4").join(".")
			unpacked_get_peers_values[unpacked_get_peers_values.length - 1][1] = dht_get_peers_values[i+1]
		end
		i += 1
	end
end
#TODO now do something with unpacked_get_peers_values...
require 'uri'
require 'net/http'
require 'bencode'

class HTTPTracker

	def initialize(addr, info_hash, my_peer_id)
		@request = URI(addr)
		params = {
			info_hash: info_hash,
			peer_id: my_peer_id,
			port: "6881",
			uploaded: "0",
			downloaded: "0", #TODO might need to update this with each handshake you send.
			left: "100000", #TODO might want to edit this, and maybe a few others.
			compact: "1",
			no_peer_id: "0",
			event: "started"
		}
		@request.query = URI.encode_www_form(params)
	end

	def connect
		puts "Connecting to HTTP tracker."
		@response = BEncode.load(Net::HTTP.get_response(@request).body)
	end

	def get_peers
		packed_peers = @response["peers"].scan(/.{6}/)
		peers = packed_peers.collect { 
			|p|
			p.unpack("a4n")
		}
		return peers
	end

end
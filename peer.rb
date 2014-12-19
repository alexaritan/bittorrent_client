require 'ipaddr'

class Peer

	def initialize(ip, port)
		@ip = ip
		@port = port

		#Set the @state of the peer.
		@state = {
			i_am_interested: false,
			peer_is_interested: false,
			i_am_unchoked: false,
			peer_is_unchoked: false
		}
	end

	def connect(handshake)
		Timeout::timeout(5){
			@connection = TCPSocket.new(IPAddr.new(@ip).to_s, @port)
			@connection.write(handshake)
			puts "Sent handshake"

			begin
				#Parse the response handshake.
				received_pstrlen = @connection.getbyte
				@peer_response = {
					received_pstrlen: received_pstrlen,
					received_pstr: @connection.read(received_pstrlen),
					received_reserved: @connection.read(8),
					received_info_hash: @connection.read(20),
					received_peer_id: @connection.read(20)
				}
			rescue
				next
			end
			puts "Received handshake"

			return @connection
		}
	end

end
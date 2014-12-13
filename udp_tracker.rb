require 'uri'
require 'socket'

class UDPTracker

	@socket = nil

	def initialize(addr, port, info_hash, my_peer_id)
		@info_hash = info_hash
		@my_peer_id = my_peer_id
		uri_addr = URI(addr)
		@socket = UDPSocket.new
		@socket.connect("#{uri_addr}", port)
	end

	def connect()
		#Send connection request to the UDP tracker.
		puts "Connecting to UDP tracker."
		connection_id = 0x41727101980
		@my_transaction_id = 11
		request_params = [connection_id >> 32, connection_id & 0xffffffff, 0, my_transaction_id].pack("NNNN")
		@socket.send("#{request_params}", 0)
	end

	def announce()
		#Receive and parse UDP tracker connection response.  Then verify response parameters.
		response = @socket.recv(1024)
		action, transaction_id, c0, c1 = response.unpack("NNNN")
		if @my_transaction_id != transaction_id || action != 0
			@socket.close
			abort("UDP TRACKER ERROR: Could not conenct to tracker.")
		end

		#Prepare parameters for announe request.
		connection_id = (c0 << 32) | c1
		@my_transaction_id = 1
		downloaded = 0
		left = 10000
		uploaded = 0
		my_ip_address = 0
		key = 111
		max_peers = 30
		params[:port] = udp_socket.addr[1]
		params[:event] = 2
		request_params = [[connection_id >> 32, connection_id & 0xffffffff, 1, my_transaction_id].pack("NNNN"),[params[:downloaded].to_i >> 32, params[:downloaded].to_i & 0xffffffff, params[:left].to_i >> 32, params[:left].to_i & 0xffffffff, params[:uploaded].to_i >> 32, params[:uploaded].to_i & 0xffffffff, params[:event], my_ip_address, key, max_peers, params[:port].to_i >> 16].pack("NNNNNNNNNNn")]
	
		#Send the announce request.
		@socket.send("#{request_params[0]}#{@info_hash}#{@my_peer_id}#{request_params[1]}", 0)
	end

	def get_peers()
		#Receive and parse UDP tracker announce response.
		response = @socket.recv(1024)
		response = response.unpack("N5NnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNn")
		action = response[0]
		transaction_id = response[1]
		if @my_transaction_id != transaction_id || action != 1
			@socket.close
			abort("UDP TRACKER ERROR: Could not announce self to tracker.")
		end
		interval = response[2] #TODO number of seconds you should wait before reannouncing yourself.
		leechers = response[3]
		seeders = response[4]
		peers = []
		i = 5
		while i<response.length && response[i] != nil
			if i%2 == 1
				peers[peers.length] = []
				peers[peers.length-1][0] = [response[i]].pack("N").unpack("C4").join(".")
				peers[peers.length-1][1] = response[i+1]
			end
			i+=1
		end

		#Close the connection.
		udp_socket.close

		return peers
	end

end
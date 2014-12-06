require 'bencode'
require 'digest/sha1'
require 'uri'
require 'net/http'
require 'ipaddr'

puts "Starting..."

#Keep track of pieces you have stored.  Each index in the array
#corresponds to the index of the piece (ie. pieces_i_have[0] = 1
#corresponds to having piece 0).
@pieces_i_have = [] #This is an array of 0s and 1s letting me know which pieces I have written to file.
@message_ids = {
	keep_alive: -1,
	choke: 0,
	unchoke: 1,
	interested: 2,
	not_interested: 3,
	have: 4,
	bitfield: 5,
	request: 6,
	piece: 7,
	cancel: 8,
	port: 9
}

#Parse .torrent file and prepare parameters for tracker request.
#TODO make this read from parameter 1.
#file = BEncode.load_file("mount_external_hdd.bash.torrent") #TODO test with PublicBT tracker instead of istole.it.
file = BEncode.load_file("ubuntu-14.10-desktop-amd64.iso.torrent")
addr = file["announce"]
info = file["info"]
info_hash = Digest::SHA1.new.digest(info.bencode)
file_length = info["length"]
file_name = info["name"]
my_peer_id = "12345439123454321230"
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
if addr[0..3] == "http"
	#Connect to tracker listed in .torrent file.
	request = URI(addr)
	request.query = URI.encode_www_form params
	response = BEncode.load(Net::HTTP.get_response(request).body)

	#Parse peers from tracker response.
	peers = response["peers"].scan(/.{6}/)
	unpacked_peers = peers.collect {
		|p|
		p.unpack("a4n")
	}
elsif addr[0..2] == "udp"
	udp_socket = UDPSocket.new
	uri_addr = URI(addr).host
	uri_port = URI(addr).port
	udp_socket.connect("#{uri_addr}", uri_port)

	#Prepare parameters for UDP tracker connect request.
	connection_id = 0x41727101980
	my_transaction_id = 11
	request_params = [connection_id >> 32, connection_id & 0xffffffff, 0, my_transaction_id].pack("NNNN")

	#Send UDP tracker connect request.
	udp_socket.send("#{request_params}", 0)

	#Receive and parse UDP tracker connect response.  Then verify response parameters.
	response = udp_socket.recv(1024)
	action, transaction_id, c0, c1 = response.unpack("NNNN")
	if my_transaction_id != transaction_id || action != 0
		udp_socket.close
		puts "UDP TRACKER ERROR 1: Transaction ID mismatch."
	end

	#Prepare parameters for UDP tracker announce request.
	connection_id = (c0 << 32) | c1
	my_transaction_id = 1
	downloaded = 0
	left = 10000
	uploaded = 0
	my_ip_address = 0
	key = 111
	max_peers = 30
	params[:port] = udp_socket.addr[1]
	params[:event] = 2
	request_params = [[connection_id >> 32, connection_id & 0xffffffff, 1, my_transaction_id].pack("NNNN"),[params[:downloaded].to_i >> 32, params[:downloaded].to_i & 0xffffffff, params[:left].to_i >> 32, params[:left].to_i & 0xffffffff, params[:uploaded].to_i >> 32, params[:uploaded].to_i & 0xffffffff, params[:event], my_ip_address, key, max_peers, params[:port].to_i >> 16].pack("NNNNNNNNNNn")]

	#Send UDP announce request.
	udp_socket.send("#{request_params[0]}#{info_hash}#{my_peer_id}#{request_params[1]}", 0)

	#Receive and parse UDP tracker announce response.
	response = udp_socket.recv(1024)
	response = response.unpack("N5NnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNn")
	action = response[0]
	transaction_id = response[1]
	if my_transaction_id != transaction_id || action != 1
		udp_socket.close
		puts "UDP TRACKER ERROR 2: Transaction ID mismatch."
	end
	interval = response[2] #TODO number of seconds you should wait before reannouncing yourself.
	leechers = response[3]
	seeders = response[4]
	unpacked_peers = []
	i = 5
	while i<response.length && response[i] != nil
		if i%2 == 1
			unpacked_peers[unpacked_peers.length] = []
			unpacked_peers[unpacked_peers.length-1][0] = [response[i]].pack("N").unpack("C4").join(".")
			unpacked_peers[unpacked_peers.length-1][1] = response[i+1]
		end
		i+=1
	end

	#Close the connection.
	begin
		udp_socket.close
	rescue
		#Just taking up space; nothing to see here.
	end
end
	
#Connect to peers with Bittorrent handshake.  Then request blocks of the desired file if all else is appropriate.
handshake = "\x13BitTorrent protocol\x00\x00\x00\x00\x00\x00\x00\x00#{params[:info_hash]}#{my_peer_id}"
unpacked_peers.each { #TODO you must compare peer_id from tracker to peer_id from peer handshake.  If they don't match, close the @connection.  You must do this IN ADDITION to checking if the hashes match.
	|ip, port|
	temp_ip = ip
	ip = IPAddr.ntop(ip) rescue ip = temp_ip
	begin
		#You have two seconds to open a TCP socket with a peer, send a handshake,
		#and receive and parse the response handshake.
		Timeout::timeout(2){
			#Send the handshake.
			@connection = TCPSocket.new(IPAddr.new(ip).to_s, port)
			@connection.write(handshake)
			puts "Sent handshake"
			
			#Parse the response handshake.
			received_pstrlen = @connection.getbyte
			peer_response = {
				received_pstrlen: received_pstrlen,
				received_pstr: @connection.read(received_pstrlen),
				received_reserved: @connection.read(8),
				received_info_hash: @connection.read(20),
				received_peer_id: @connection.read(20)
			}
			puts "Received handshake"
		}

		#Set the @state of the peer.
		@state = {
			i_am_interested: false,
			peer_is_interested: false,
			i_am_unchoked: false,
			peer_is_unchoked: false
		}

		#Prepare variables for REQUEST message for when peer unchokes you.
		piece_length = info["piece length"].to_i
		if file_length%piece_length == 0
			number_of_pieces = file_length/piece_length
		else
			number_of_pieces = file_length/piece_length + 1
		end

		size_of_last_piece = piece_length
		size_of_last_piece = file_length%piece_length unless file_length%piece_length == 0
		#remaining_size_of_piece = file_length
		remaining_size_of_piece = piece_length if piece_length <= file_length
		remaining_size_of_piece = file_length.to_i if piece_length > file_length.to_i
		piece_index = 0 #Increment this by 1 (or to next available piece) after each piece is finished.
		begin_block = 0 #Increment this by block_size after each block request.
		block_size = 2**14 #This stays constant.
		@block_storage = []
		@pieces_to_write_to_file_later = {}
		@next_piece_to_write_to_file = 0
		bitfield_row_that_corresponds_with_piece_index = piece_index/8
		bitfield_column_that_corresponds_with_piece_index = piece_index%8


		#Parse incoming messages and handle them appropriately.
		while true do #TODO change to "while there are still pieces left".
			if @pieces_i_have[piece_index] != 1
				puts "Looking for incoming message"
				message_length = 0
				begin
					#Timeout::timeout(10){
						message_length = @connection.read(4).unpack("N")[0]# rescue next
					#}
				rescue
				end
				if message_length == 0
					#puts "Received keep-alive"
				elsif message_length > 0
					message_id = @connection.read(1).bytes.to_a[0]

					if message_id == @message_ids[:choke]
						puts "Received choke"
						@state[:i_am_unchoked] = false
					elsif message_id == @message_ids[:unchoke]
						puts "Received unchoke"
						@state[:i_am_unchoked] = true
					elsif message_id == @message_ids[:interested]
						puts "Received interested"
						@state[:peer_is_interested] = true
					elsif message_id == @message_ids[:not_interested]
						puts "Received not interested"
						@state[:peer_is_interested] = false
					elsif message_id == @message_ids[:have]
						puts "Received have"
						have_index = @connection.read(4).unpack("N")[0].to_i
						@bitfield[have_index/8][have_index%8] = 1
					elsif message_id == @message_ids[:bitfield]
						puts "Received bitfield"
						@bitfield = @connection.read(message_length-1)
					elsif message_id == @message_ids[:request]
						puts "Received request (uhh, what?)"
						message_body = @connection.read(message_length-1)
						#TODO implement support for requests.
						#This is a very, VERY low priority.
					elsif message_id == @message_ids[:piece]
						puts "Received block #{begin_block} in piece #{piece_index}"
						begin_block += (message_length - 9)
						remaining_size_of_piece -= (message_length - 9)

						#Parse the returned block.
						returned_piece_index = @connection.read(4)
						returned_block_offset = @connection.read(4)
						returned_block = @connection.read(message_length - 9)
						@block_storage[@block_storage.length] = returned_block

						if remaining_size_of_piece == 0
							#TODO validate the piece and then write @block_storage to a file after each piece is received.
							puts "RECEIVED ENTIRE PIECE #{piece_index}!!!"
							@pieces_i_have[piece_index] = 1
							if @next_piece_to_write_to_file == piece_index
								File.open("#{file_name}", "a") do |file|
									@block_storage.each do |block|
										file.write block
									end
								end
								@next_piece_to_write_to_file += 1

								#Check to see if the piece after the one you just stored has already
								#been downloaded and is waiting to be written to file.
								while @pieces_to_write_to_file_later[@next_piece_to_write_to_file] != nil do
									File.open("#{file_name}", "a") do |file|
										@pieces_to_write_to_file_later[@next_piece_to_write_to_file].each do |block|
											file.write block
										end
									end
									@pieces_to_write_to_file_later[@next_piece_to_write_to_file] = nil
									@next_piece_to_write_to_file += 1
								end
							else
								piece_to_write = @block_storage
								@pieces_to_write_to_file_later[piece_index: piece_to_write] #Stores the array containing the entire piece at the index equivalent to the piece index.
							end
							piece_index += 1
							begin_block = 0
							bitfield_row_that_corresponds_with_piece_index = piece_index/8
							bitfield_column_that_corresponds_with_piece_index = piece_index%8
							@block_storage = []
							if piece_index == number_of_pieces - 1
								remaining_size_of_piece = size_of_last_piece
							elsif piece_index == number_of_pieces
								break
							else
								remaining_size_of_piece = piece_length
							end
						end
					elsif message_id == @message_ids[:cancel]
						puts "Received cancel"
						message_body = @connection.read(message_length-1)
					elsif message_id == @message_ids[:port]
						puts "Received port"
						message_body = @connection.read(message_length-1)
					else
						puts "Received unknown message: ID #{message_id}"
					end

					if @state[:i_am_unchoked] && @bitfield[bitfield_row_that_corresponds_with_piece_index][bitfield_column_that_corresponds_with_piece_index] != 1
						#Encode parameters for REQUEST message.
						request_message_length = [13].pack("N")
						request_message_id = "\6"
						request_piece_index = [piece_index].pack("N")
						request_begin_block = [begin_block].pack("N")
						request_block_size = [block_size].pack("N")

						#Send REQUEST message.
						if remaining_size_of_piece >= block_size
							@connection.write(request_message_length + request_message_id + request_piece_index + request_begin_block + request_block_size)
							puts "Sent request of #{block_size} for piece #{piece_index}"
						else
							request_block_size = [remaining_size_of_piece].pack("N")
							@connection.write(request_message_length + request_message_id + request_piece_index + request_begin_block + request_block_size)
							puts "Sent request of #{remaining_size_of_piece} for piece #{piece_index}"
						end
					else
						#Send INTERESTED message to the connected peer.
						@connection.write("\0\0\0\1\2") #First 4 bytes = 1, meaning length of payload = 1 byte.  5th byte is id = 2, which corresponds to INTERESTED message.
						puts "Sent interested"
						@state[:i_am_interested] = true
					end
				end
			else
				piece_index += 1
				bitfield_row_that_corresponds_with_piece_index = piece_index/8
				bitfield_column_that_corresponds_with_piece_index = piece_index%8
			end
		end
		if @pieces_i_have.length == number_of_pieces
			@finished = true
			@pieces_i_have.each do |piece|
				@finished = false if piece == 0
			end
		end

		@connection.close
		break if @finished
	rescue => exception
		puts exception
		@connection.close if @connection != nil
	end
}

#TODO support torrents with multiple files.
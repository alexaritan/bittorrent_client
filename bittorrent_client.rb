require 'bencode'
require 'digest/sha1'
require 'uri'
require 'net/http'
require 'ipaddr'

#Keep track of pieces you have stored.  Each index in the array
#corresponds to the index of the piece (ie. pieces_i_have[0]
#corresponds to piece 0).
@pieces_i_have = []
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
file = BEncode.load_file "ubuntu-14.10-desktop-amd64.iso.torrent"
addr = file["announce"]
info = file["info"]
info_hash = Digest::SHA1.new.digest(info.bencode)
file_length = info["length"]
file_name = info["name"]
id = "12345439123454321230"
params = {
	info_hash: info_hash,
	peer_id: id,
	port: "6881",
	uploaded: "0",
	downloaded: "0",
	left: "100000", #Might want to edit this, and maybe a few others.
	compact: "1",
	no_peer_id: "0",
	event: "started"
}

#Connect to tracker listed in .torrent file.
request = URI addr
request.query = URI.encode_www_form params
response = BEncode.load Net::HTTP.get_response(request).body

#Parse peers from tracker response.
peers = response["peers"].scan /.{6}/
unpacked_peers = peers.collect {
	|p|
	p.unpack "a4n"
}

#Connect to peers with Bittorrent handshake.  Then request blocks of the desired file if all else is appropriate.
handshake = "\x13BitTorrent protocol\x00\x00\x00\x00\x00\x00\x00\x00#{params[:info_hash]}#{id}"
unpacked_peers.each { #TODO you must compare peer_id from tracker to peer_id from peer handshake.  If they don't match, close the @connection.  You must do this IN ADDITION to checking if the hashes match.
	|ip, port|
	begin
		#You have two seconds to open a TCP socket with a peer, send a handshake,
		#and receive and parse the response handshake.
		Timeout::timeout(2){
			#Send the handshake.
			@connection = TCPSocket.new(IPAddr.new_ntoh(ip).to_s, port)
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

		#Set the state of the peer.
		state = {
			i_am_interested: false,
			peer_is_interested: false,
			i_am_unchoked: false,
			peer_is_unchoked: false
		}

		#Parse the optional bitfield message that may be received immediately after the handshake.
		bitfield_length = @connection.read(4)
		bitfield_length = bitfield_length.unpack("N")[0] if bitfield_length != nil
		bitfield_message_id = @connection.read(1)
		bitfield_message_id = bitfield_message_id.bytes.to_a[0] if bitfield_message_id != nil
		#TODO if the length of the bitfield is not the correct size, you should drop the @connection.  I'm not sure how to tell if it is the correct size as of right now though...
		if bitfield_message_id != 5
			puts "No bitfield!"
		else
			bitfield = @connection.read(bitfield_length - 1).unpack("B8" * (bitfield_length-1))
			puts "Initial bitfield received"
			#TODO implement support for incomplete bitfields followed by HAVE messages.  This would require you to set some additional bits in the bitfield according to the received HAVE messages.
		end

		#Send INTERESTED message to the connected peer.
		@connection.write("\0\0\0\1\2") #First 4 bytes = 1, meaning length of payload = 1 byte.  5th byte is id = 2, which corresponds to INTERESTED message.
		puts "Sent interested"

		#Prepare variables for REQUEST message for when peer unchokes you.
		piece_length = info["piece length"].to_i
		if file_length%piece_length == 0
			number_of_pieces = file_length/piece_length
		else
			number_of_pieces = file_length/piece_length + 1
		end

		size_of_last_piece = file_length%piece_length
		remaining_size_of_piece = piece_length
		piece_index = 0 #Increment this by 1 (or to next available piece) after each piece is finished.
		begin_block = 0 #Increment this by block_size after each block request.
		block_size = 2**14 #This stays constant.
		@block_storage = []
		bitfield_row_that_corresponds_with_piece_index = piece_index/8
		bitfield_column_that_corresponds_with_piece_index = piece_index%8

		puts "Piece length: #{piece_length}"
		#Parse incoming messages and handle them appropriately.
		while true do #TODO change to "while there are still pieces left".
			if @pieces_i_have[piece_index] != 1 && bitfield[bitfield_row_that_corresponds_with_piece_index][bitfield_column_that_corresponds_with_piece_index] == 1
				puts "Looking for incoming message"
				message_length = @connection.read(4).unpack("N")[0]

				if message_length == 0
					#puts "Keep alive received"
				elsif message_length > 0
					message_id = @connection.read(1).bytes.to_a[0]

					if message_id == @message_ids[:choke]
						puts "Choke received"
						state[:i_am_unchoked] = false
					elsif message_id == @message_ids[:unchoke]
						puts "Unchoke received"
						state[:i_am_unchoked] = true
					elsif message_id == @message_ids[:interested]
						puts "Interested received"
						state[:peer_is_interested] = true
					elsif message_id == @message_ids[:not_interested]
						puts "Not interested received"
						state[:peer_is_interested] = false
					elsif message_id == @message_ids[:have]
						puts "Have received"
						#TODO implement suppost for HAVE messages.
						message_body = @connection.read(message_length-1)
					elsif message_id == @message_ids[:bitfield]
						puts "Bitfield received"
						message_body = @connection.read(message_length-1)
					elsif message_id == @message_ids[:request]
						puts "Request received (uhh, what?)"
						message_body = @connection.read(message_length-1)
					elsif message_id == @message_ids[:piece]
						puts "Received block #{begin_block} in piece #{piece_index}"
						begin_block += (message_length - 9)
						remaining_size_of_piece -= (message_length - 9)

						#Parse the returned block.
						returned_start_index_of_block = @connection.read(4)
						returned_block_offset = @connection.read(4)
						returned_block = @connection.read(message_length - 9)
						@block_storage[@block_storage.length] = returned_block

						if remaining_size_of_piece == 0
							puts "ENTIRE PIECE #{piece_index} RECEIVED!!!"
							@pieces_i_have[piece_index] = 1
							piece_index += 1
							begin_block = 0
							bitfield_row_that_corresponds_with_piece_index = piece_index/8
							bitfield_column_that_corresponds_with_piece_index = piece_index%8
							#TODO validate the piece and then write @block_storage to a file after each piece is received.
							File.open("#{file_name}", "a") do |file|
								@block_storage.each do |block|
									file.puts block
								end
							end
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
						puts "Cancel received"
						message_body = @connection.read(message_length-1)
					elsif message_id == @message_ids[:port]
						puts "Port received"
						message_body = @connection.read(message_length-1)
					else
						puts "Unknown message received: ID #{message_id}"
					end

					if state[:i_am_unchoked]
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
							@connection.write(request_message_length + request_message_id + request_piece_index + request_begin_block + remaining_size_of_piece)
							puts "Sent request of #{remaining_size_of_piece}"
						end
					else
						#Send INTERESTED message to the connected peer.
						@connection.write("\0\0\0\1\2") #First 4 bytes = 1, meaning length of payload = 1 byte.  5th byte is id = 2, which corresponds to INTERESTED message.
						puts "Sent interested"
					end
				end
			elsif @pieces_i_have[piece_index] == 1
				piece_index += 1
				bitfield_row_that_corresponds_with_piece_index = piece_index/8
				bitfield_column_that_corresponds_with_piece_index = piece_index%8
			end
		end
		@finished = true
		@pieces_i_have.each do |piece|
			@finished = false if piece == 0
		end

		@connection.close
		break if @finished
	rescue => exception
		puts exception
		@connection.close if @connection != nil
	end
}

#TODO right now you just write to the end of the file whenever you get a piece,
#but what if the first peer doesn't have all of the pieces and you get some of
#them from the second peer?  Those pieces would be written at the end when
#they shouldn't be.  Fix that.

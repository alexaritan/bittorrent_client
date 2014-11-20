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
		remaining_size_of_piece = piece_length
		piece_index = 0 #Increment this by 1 (or to next available piece) after each piece is finished.
		begin_block = 0 #Increment this by block_size after each block request.
		block_size = 2**14 #This stays constant.

		puts "Piece length: #{piece_length}"
		#Parse incoming messages and handle them appropriately.
		while true do
			puts "Looping"
			message_length = @connection.read(4).unpack("N")[0]

			if message_length == 0
				#puts "Keep alive received"
			elsif message_length > 0
				message_id = @connection.read(1).bytes.to_a[0]
				message_body = @connection.read(message_length-1)

				#TODO parse the message payload for every message otherwise following messages are thrown off.
				if message_id == @message_ids[:choke]
					puts "Choke received"
					state[:i_am_unchoked] = false
				elsif message_id == @message_ids[:unchoke]
					puts "Unchoke received"
					state[:i_am_unchoked] = true
				elsif message_id == @message_ids[:interested]
					puts "Interested received"
				elsif message_id == @message_ids[:not_interested]
					puts "Not interested received"
				elsif message_id == @message_ids[:have]
					puts "Have received"
				elsif message_id == @message_ids[:bitfield]
					puts "Bitfield received"
				elsif message_id == @message_ids[:request]
					puts "Request received (uhh, what?)"
				elsif message_id == @message_ids[:piece]
					puts "BLOCK RECEIVED!!!"
					#TODO parse and store the PIECE message.
					begin_block += block_size
					remaining_size_of_piece -= block_size
				elsif message_id == @message_ids[:cancel]
					puts "Cancel received"
				elsif message_id == @message_ids[:port]
					puts "Port received"
				else
					puts "Unknown message received #{message_id}"
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
						puts "Sent request of #{block_size}"
					elsif remaining_size_of_piece == 0
						#Do something here - you have the whole piece.
						#Validate the piece, store it, and move onto the next one.
						puts "ENTIRE PIECE RECEIVED!!"
						break #TODO GET RID OF THIS BREAK!!!!!!!!!!!!!
						#IT IS PURELY FOR TESTING!!!
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
		end










=begin
	THIS IS ALL OLD CODE THAT I AM WORKING ON REWRITING!!!

		#Wait for UNCHOKE message.  TODO implement time limit for this loop.
		#TODO you may need to also UNCHOKE other peers.
		message_id = -1
		while message_id != 1 && message_id != nil do
			message_length = @connection.read(4).unpack("N")[0]
			message_id = @connection.read(1).bytes.to_a[0]
		end
		puts "Unchoked by peer"

		#Prepare necessary information for REQUEST message.
		#TODO find out how to handle the last piece of a file.
		piece_length = info["piece length"].to_i
		remaining_size_of_piece = piece_length
		piece_index = 0 #Increment this by 1 (or to next available piece) after each piece is finished.
		begin_block = 0 #Increment this by block_size after each block request.
		block_size = 2**14 #This stays constant.
		
		#Encode parameters for REQUEST message.
		request_message_length = [13].pack("N")
		request_message_id = "\6"
		request_piece_index = [piece_index].pack("N")
		request_begin_block = [begin_block].pack("N")
		request_block_size = [block_size].pack("N")

=begin
			I AM CURRENTLY HAVING A PROBLEM WHERE AFTER REQUESTING
			ONE BLOCK OF THE FILE, I AM BEING CHOKED BY MY PEER.

			YOU NEED TO CHECK FOR OTHER MESSAGE IDS BESIDES JUST 7 BELOW
			AND HANDLE THEM APPROPRIATELY!!!

		while remaining_size_of_piece > 0 do #Keep requesting blocks until the remaining part of the piece is smaller than the default block size.
			message_id = -1
			#puts "Downloading piece #{piece_index}"

			#Send REQUEST message.
			if remaining_size_of_piece >= block_size
				@connection.write(request_message_length + request_message_id + request_piece_index + request_begin_block + request_block_size)
			else
				@connection.write(request_message_length + request_message_id + request_piece_index + request_begin_block + remaining_size_of_piece)
			end
=begin
			This is old code.  It produces a problem where after the first piece
			is requested, the connection is choked, and then all following
			messages are parsed incorrectly because the code depends on them
			being PIECE messages when they aren't.

			while message_id != 7 && message_id != nil do
				message_length = @connection.read(4).unpack("N")[0]
				message_id = @connection.read(1).bytes.to_a[0]
				puts "Message id: #{message_id}"
			end


			

			puts "Storing block..." #TODO You don't actually store the block yet.
			remaining_size_of_piece -= block_size
			begin_block += block_size
			puts "Remaining piece size: #{remaining_size_of_piece}"
		end

		#TODO check the hash of a piece when it is done downloading.
		#Row*8 + column of the bitfield to check if the peer as the piece.		
=end


		@connection.close
	rescue => exception
		puts exception
		@connection.close if @connection != nil
	end
}
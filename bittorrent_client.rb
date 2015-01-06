require 'bencode'
require 'digest/sha1'
require 'uri'
require 'net/http'
require 'ipaddr'
require_relative 'udp_tracker'
require_relative 'http_tracker'
require_relative 'dht'
require_relative 'peer'

if ARGV[0] == "--help"
	abort("Usage: ruby bittorrent_client.rb [file.torrent | \"magnet link (in quotes)\"] [tracker | dht]")
end

torrent_info_in = ARGV[0]
if !torrent_info_in.include?(".torrent") && torrent_info_in[0..5] != "magnet"
	abort("Unsupported file type.  Only .torrent files and magnet links are supported.")
end

connection_method = ARGV[1]
if connection_method != "tracker" && connection_method != "dht"
	abort("Unsupported connection method.  Only 'tracker' and 'dht' are supported.")
end

puts "Starting..."

#TODO MAGNET LINKS!
#Most magnet links come with a tracker as part of the URL.  Even if the
#person using your client decides to use the DHT instead of a tracker, you
#can look up the tracker to get peers as backups.  No word on getting
#info on metadata though...

#Keep track of pieces you have stored.  Each index in the array
#corresponds to the index of the piece (ie. pieces_i_have[0] = 1
#corresponds to having piece 0).
@pieces_i_have = [] #This is an array of 0s and 1s letting me know which pieces I have written to file.
@pieces_to_write_to_file_later = {}
@next_piece_to_write_to_file = 0
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

#Parse .torrent file or magnet link and prepare parameters for tracker request or dht bootstrapping.
if torrent_info_in.include?(".torrent")
	file = BEncode.load_file("#{torrent_info_in}")
	addr = file["announce"]
	info = file["info"]
	info_hash = Digest::SHA1.new.digest(info.bencode)
	my_peer_id = "12345439123454321230"
	file_name = info["name"]
	file_length = info["length"]
	piece_length = info["piece length"]
	number_of_files = 1
	remaining_size_of_file = file_length
	file_currently_downloading = 0
	if file_length == nil #This will be true if there exists more than one file in the torrent.
		file_length = 0
		filenames = []
		files = info["files"]
		files.each do |file|
			file_length += file["length"]
			file["path"].each do |name|
				filenames[filenames.length] = ""
				filenames[filenames.length - 1] += name
			end
		end
		number_of_files = filenames.length
		file_name = filenames[0]
		remaining_size_of_file = files[file_currently_downloading]["length"]
	end
elsif torrent_info_in[0..5] == "magnet" #PUT ARGUMENT IN QUOTES! TODO finish magnet link support.
	puts "OH NO A MAGNET LINK"
	info_hash_location = torrent_info_in.index("btih:")
	info_hash = torrent_info_in[info_hash_location+5..info_hash_location+44]
end

if connection_method == "tracker"
	if addr[0..3] == "http"
		http_tracker = HTTPTracker.new(addr, info_hash, my_peer_id)
		http_tracker.connect
		unpacked_peers = http_tracker.get_peers
	elsif addr[0..2] == "udp"
		udp_tracker = UDPTracker.new(URI(addr).host, URI(addr).port, info_hash, my_peer_id)
		udp_tracker.connect
		udp_tracker.announce
		unpacked_peers = udp_tracker.get_peers
	end
elsif connection_method == "dht"
	dht = DHT.new(info_hash)
	dht.bootstrap
	unpacked_peers = dht.get_peers
end
	
#Connect to peers with Bittorrent handshake.  Then request blocks of the desired file if all else is appropriate.
handshake = "\x13BitTorrent protocol\x00\x00\x00\x00\x00\x00\x00\x00#{info_hash}#{my_peer_id}"
while true do
	unpacked_peers.each { #TODO you must compare peer_id from tracker to peer_id from peer handshake.  If they don't match, close the @connection.  You must do this IN ADDITION to checking if the hashes match.
		|ip, port|
		temp_ip = ip
		ip = IPAddr.ntop(ip) rescue ip = temp_ip
		begin
			#You have two seconds to open a TCP socket with a peer, send a handshake,
			#and receive and parse the response handshake.
			peer = Peer.new(ip, port)
			@connection = peer.connect(handshake)

			#Prepare variables for REQUEST message for when peer unchokes you.
			begin_block = 0 #Increment this by block_size after each block request.
			piece_index = 0 #Increment this by 1 (or to next available piece) after each piece is finished.
			if number_of_files > 1
				i = 0
				len = 0
				while i < file_currently_downloading do
					len += files[i]["length"]
					i += 1
				end
				if files[file_currently_downloading]["length"]%piece_length == 0
					piece_index = len/piece_length
				else
					piece_index = len/piece_length + 1 unless file_currently_downloading == 0
				end
				remaining_size_of_piece = piece_length if piece_length <= files[file_currently_downloading]["length"]
				remaining_size_of_piece = files[file_currently_downloading]["length"] if piece_length > files[file_currently_downloading]["length"]
				remaining_size_of_piece = piece_length - begin_block if file_currently_downloading > 1 && begin_block > 0 && just_switched_to_next_file && (piece_length - begin_block) < files[file_currently_downloading]["length"]
				begin_block = files[file_currently_downloading - 1]["length"]%piece_length if file_currently_downloading > 1
			else
				if file_length%piece_length == 0
					size_of_last_piece = piece_length
				else
					size_of_last_piece = file_length%piece_length
				end
				remaining_size_of_piece = piece_length if piece_length <= file_length
				remaining_size_of_piece = file_length if piece_length > file_length
			end
			block_size = 2**14 #This stays constant.
			@block_storage = []
			bitfield_row_that_corresponds_with_piece_index = piece_index/8
			bitfield_column_that_corresponds_with_piece_index = piece_index%8

			##THIS NEEDS TO BE MOVED COMPLETELY INTO THE PEER CLASS!!!
			@state = {
				i_am_interested: false,
				peer_is_interested: false,
				i_am_unchoked: false,
				peer_is_unchoked: false
			}
			##END NEED TO MOVE.

			#Parse incoming messages and handle them appropriately.
			while true do
				if @pieces_i_have[piece_index] != 1
					puts "Looking for incoming message"
					message_length = 0
					begin
						message_length = @connection.read(4).unpack("N")[0]# rescue next
					rescue
						break
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
							have_index = @connection.read(4)
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
							remaining_size_of_file -= (message_length - 9)

							#Parse the returned block.
							returned_piece_index = @connection.read(4)
							returned_block_offset = @connection.read(4)
							returned_block = @connection.read(message_length - 9)
							@block_storage[@block_storage.length] = returned_block

							if remaining_size_of_file == 0
								puts ""
								puts "AHHHHHHHHH!!!! I GOT AN ENTIRE FILE!!!!"
								puts ""
								if @next_piece_to_write_to_file == piece_index
									puts "Writing to file..."
									File.open("#{file_name}", "a") do |file|
										@block_storage.each do |block|
											file.write block
										end
									end

									#Check to see if the piece after the one you just stored has already
									#been downloaded and is waiting to be written to file.
									while @pieces_to_write_to_file_later[@next_piece_to_write_to_file] != nil do
										#TODO there is an edge case here where you want to check to see if you're about to write a piece that has been stored that contains blocks from two files.  Unlikely but possible.
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
									@pieces_to_write_to_file_later[piece_index] = piece_to_write if @pieces_to_write_to_file_later[piece_index] == nil #Stores the array containing the entire piece at the index equivalent to the piece index.
									@pieces_to_write_to_file_later[piece_index] += piece_to_write if @pieces_to_write_to_file_later[piece_index] != nil
								end
								file_currently_downloading += 1
								file_name = filenames[file_currently_downloading] if number_of_files > 1
								remaining_size_of_file = files[file_currently_downloading]["length"] if number_of_files > 1 && file_currently_downloading < number_of_files
								@block_storage = []
							end

							if remaining_size_of_piece == 0
								#TODO validate the piece before writing @block_storage to a file after each piece is received.
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
									@pieces_to_write_to_file_later[piece_index] = piece_to_write if @pieces_to_write_to_file_later[piece_index] == nil #Stores the array containing the entire piece at the index equivalent to the piece index.
									@pieces_to_write_to_file_later[piece_index] += piece_to_write if @pieces_to_write_to_file_later[piece_index] != nil
								end
								piece_index += 1
								begin_block = 0
								bitfield_row_that_corresponds_with_piece_index = piece_index/8
								bitfield_column_that_corresponds_with_piece_index = piece_index%8
								@block_storage = []
								if piece_index*piece_length >= file_length && (piece_index-1)*piece_length < file_length
									remaining_size_of_piece = size_of_last_piece
								elsif piece_index*piece_length > file_length && (piece_index-1)*piece_length >= file_length
									break
								else
									remaining_size_of_piece = piece_length
								end
							end

							#Check if entire torrent is done.
							if file_currently_downloading == number_of_files
								if file_length%piece_length != 0 && piece_index == file_length/(piece_length + 1)
									puts "DONE!"
									exit
								elsif file_length%piece_length == 0 && piece_index == file_length/piece_index
									puts "DONE!"
									exit
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
							if remaining_size_of_file > block_size	
								@connection.write(request_message_length + request_message_id + request_piece_index + request_begin_block + request_block_size)
								puts "Sent request of #{block_size} for piece #{piece_index}"
							elsif remaining_size_of_file <= block_size
								request_block_size = [remaining_size_of_file].pack("N")
								@connection.write(request_message_length + request_message_id + request_piece_index + request_begin_block + request_block_size)
								puts "Sent request of #{remaining_size_of_file} for piece #{piece_index} at block offset #{begin_block}"
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
			if file_length%piece_length > 0
				if @pieces_i_have == file_length/piece_length + 1
					@finished = true
					@pieces_i_have.each do |piece|
						@finished = false if piece == 0
					end

				end
			else
				if @pieces_i_have == file_length/piece_length
					@finished = true
					@pieces_i_have.each do |piece|
						@finished = false if piece == 0
					end

				end
			end

			@connection.close if $connection != nil
			break if @finished
		rescue => exception
			puts exception
			@connection.close if @connection != nil rescue next
		end
	}
end
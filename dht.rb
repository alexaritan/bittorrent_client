require 'socket'

class DHT

	def initialize(info_hash)
		@info_hash = info_hash
		@my_node_id = "37914862501111111211"
		@nodes_to_visit = []
		@nodes_visited = []
		@params = {
			t: "aa",
			y: "q",
			q: "",
			a: {}
		}
		@node_offset = 0
		@peers = []
	end

	def bootstrap
		@uri_addr = URI("router.bittorrent.com")
		@port = 6881
	end

	def find_nodes
		response = nil
		while true do
			puts "Connecting to #{@uri_addr} on port #{@port}"
			@socket = UDPSocket.new
			@socket.connect("#{@uri_addr}", @port)
			@params[:q] = "get_peers"
			@params[:a] = {
				id: @my_node_id,
				info_hash: @info_hash
			}
			@socket.send(@params.bencode, 0)

			begin
				Timeout::timeout(5){
					@nodes_visited[@nodes_visited.length] = [@uri_addr, @port]
					response = BEncode.load(@socket.recv(1024))
				}
				@node_offset = 0
			rescue
				@socket.close #This might cause an exception.  Just remove this line if it does.
				while true do
					@node_offset += 1
					break if @node_offset < @nodes_to_visit.length && !@nodes_visited.include?(@nodes_to_visit[@node_offset])
				end
				@uri_addr = URI(@nodes_to_visit[@node_offset][0])
				@port = @nodes_to_visit[@node_offset][1]
				abort("Sorry, no more available nodes.") if @node_offset >= @nodes_to_visit.length && @peers.length == 0
				break if @node_offset >= @nodes_to_visit.length && @peers.length > 0
				puts "Trying different node."
				next
			end

			return response["r"]["values"] if response["r"]["values"] != nil

			@nodes_to_visit.reverse!
			nodes = response["r"]["nodes"].bytes.to_a
			i = 0
			while (i*26)+25 < response["r"]["nodes"].bytes.to_a.length do
				node_id = nodes[(i*26)..((i*26)+19)]
				node_ip = nodes[((i*26)+20)..((i*26)+23)].join(".")
				node_port = (nodes[(i*26)+24] << 8) | nodes[(i*26)+25]

				@nodes_to_visit[@nodes_to_visit.length] = [URI(node_ip), node_port]
				i += 1
			end
			@nodes_to_visit.reverse!

			@nodes_to_visit.each do |node|
				if !@nodes_visited.include?([node[0], node[1]])
					@uri_addr = node[0]
					@port = node[1]
					break
				end
			end
			@socket.close
		end
	end

	def get_peers
		while true do
			values = find_nodes
			i = @peers.length
			while (i*6)+5 < values.length
				puts "Adding peer to list."
				peer = values[i].to_s.unpack("Nn")
				peer_ip = [peer[0]].pack("N").unpack("C4").join(".")
				peer_port = peer[1]
				@peers[@peers.length] = [peer_ip, peer_port]
				i += 1
			end
			break if @peers.length > 5
			@nodes_to_visit.each do |node|
				if !@nodes_visited.include?([node[0], node[1]])
					@uri_addr = node[0]
					@port = node[1]
					break
				end
			end
		end
		return @peers
	end

end
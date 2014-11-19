require "socket"

udp_socket = UDPSocket.new
udp_socket.send "Help, is anyone out there?", 0, "google.com", 10001
    function automatic int hex_digit(input byte value);
        if (value >= "0" && value <= "9") return int'(value)-48;
        if (value >= "a" && value <= "f") return int'(value)-87;
        if (value >= "A" && value <= "F") return int'(value)-55;
        $fatal(1,"invalid vector hex digit %h",value); return 0;
    endfunction
    function automatic logic [7:0] hex_byte(input string value,input int index);
        return 8'(hex_digit(value[index*2])*16+hex_digit(value[index*2+1]));
    endfunction
    function automatic logic [7:0] error_number(input string value);
        case (value)
            "TOO_LONG": return DBG_ERR_TOO_LONG; "COBS_INVALID": return DBG_ERR_COBS_INVALID;
            "TOO_SHORT": return DBG_ERR_TOO_SHORT; "BAD_LENGTH": return DBG_ERR_BAD_LENGTH;
            "BAD_CRC": return DBG_ERR_BAD_CRC; "BAD_VERSION": return DBG_ERR_BAD_VERSION;
            "BAD_RESERVED": return DBG_ERR_BAD_RESERVED; "BAD_CHANNEL": return DBG_ERR_BAD_CHANNEL;
            "BAD_KIND": return DBG_ERR_BAD_KIND; "TIMEOUT": return DBG_ERR_TIMEOUT;
            default: begin $fatal(1,"unknown frame error %s",value); return 0; end
        endcase
    endfunction
    task automatic unpack_vector(input string line,output dbg_frame_t packet,output string wire_hex);
        string kind,name,payload;
        int fields;
        logic [7:0] version,channel,packet_kind,flags;
        logic [15:0] opcode,status;
        logic [31:0] request_id;
        logic [63:0] session_id;
        packet='0;
        fields=$sscanf(line,"%s %s %d %d %d %d %h %h %h %h %s %s",
            kind,name,version,channel,packet_kind,flags,opcode,status,
            request_id,session_id,payload,wire_hex);
        assert (fields == 12 && kind=="ok" && name.len()>0) else $fatal(1,"bad packet vector %s",line);
        packet.version=version; packet.channel=channel; packet.kind=packet_kind;
        packet.flags=flags; packet.opcode=opcode; packet.status=status;
        packet.request_id=request_id; packet.session_id=session_id;
        packet.length=(payload == "-") ? 0 : 16'(payload.len()/2);
        for (int i=0;i<int'(packet.length);i=i+1) packet.payload[i*8+:8]=hex_byte(payload,i);
    endtask

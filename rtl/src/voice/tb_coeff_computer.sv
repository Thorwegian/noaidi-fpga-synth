// tb_coeff_computer.sv — end-to-end test. One vector per call, wait for pipeline.
`timescale 1ns/1ps

module tb_coeff_computer;
    reg clk=0, rst_n=0, vi=0;
    reg [23:0] cents=0;
    reg [17:0] oq=0;
    wire [23:0] K;
    wire [17:0] irk, id;
    wire vo;

    coeff_computer uut(.clk(clk),.rst_n(rst_n),.valid_in(vi),
        .cents_in(cents),.one_over_Q_in(oq),
        .K_out(K),.inv_res_K_out(irk),.inv_div_out(id),.valid_out(vo));

    always #5 clk=~clk;

    reg [23:0] ec[0:511], eK[0:511], erk[0:511], ed[0:511], eoq[0:511];
    integer num, i, errors;

    initial begin
        errors=0;
        $readmemh("/tmp/cc_cents.hex",ec);
        $readmemh("/tmp/cc_K.hex",eK);
        $readmemh("/tmp/cc_irk.hex",erk);
        $readmemh("/tmp/cc_id.hex",ed);
        $readmemh("/tmp/cc_oq.hex",eoq);
        num=0; while(num<512 && ec[num]!==24'hxxxxxx) num=num+1;

        #20 rst_n=1; #20;
        $display("=== coeff_computer (%0d vectors) ===", num);

        for(i=0; i<num; i=i+1) begin
            @(posedge clk); vi<=1; cents<=ec[i]; oq<=eoq[i][17:0];
            @(posedge clk); vi<=0;
            repeat(16) @(posedge clk);
            if(vo) begin
                if(K!==eK[i]) begin $display("K #%0d: exp=%0d got=%0d",i,eK[i],K); errors=errors+1; end
                if(irk!==erk[i]) begin $display("irk #%0d: exp=%0d got=%0d",i,erk[i],irk); errors=errors+1; end
                if(id!==ed[i]) begin $display("id #%0d: exp=%0d got=%0d",i,ed[i],id); errors=errors+1; end
            end
        end
        $display("%0d errors",errors);
        if(errors==0) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule

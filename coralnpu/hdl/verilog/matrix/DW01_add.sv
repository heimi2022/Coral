module DW01_add (A,B,CI,SUM,CO);

   parameter integer width=4;

   // port decalrations

   input [width-1 : 0] 	A,B;
   input 		CI;
   
   output [width-1 : 0] SUM;
   output 		CO;

  wire [width : 0]      tmp_out;   

 

  assign tmp_out = ((^(A ^ A) !== 1'b0) || (^(B ^ B) !== 1'b0)) ? {width+1{1'bx}} : A+B+CI;
  assign CO = tmp_out[width];
  assign SUM = tmp_out[width-1 : 0];

   
endmodule  // DW01_add;

## Decrypting RSA firmware
In recent firmware releases, TP-Link has started using hybrid cryptographic scheme that combines both RSA and AES to secure their modern "Cloud" firmware. Multiple TP Link models, not just limited to AX53, but also AX55, AX72, AX56, AX57, Deco Lineup and multiple other models. The firmware cannot be unpacked unless decrypting it. If we track down firmware upgrade path of AX53, it seems this nvrammanager binary in `/usr/bin` is responsible for decrypting the fw before upgrading. So we can exploit this mechanism by simulating the router environment using qemu-arm-static and a chroot jail. As soon as nvrammanager decrypts the firmware, we steal it.

Look at the downloaded firmware name, eg `ax53v1-up-ax53v1-only-ver1-7-1-P1[20260213-rel87654]-2048_sign.bin` -- see that `-2048_sign` at the end? those are encrypted fw. ie a normal fw would be named something like `ax53v1-up-ax53v1-only-ver1-4-4-P1[20250603-rel74380]-1024_sign.bin` -- notice the `-1024_sign` at the end. If firmware follows separate naming scheme, we can figure out if it's encrypted or not using hexdump. 

```plaintext
# Command
hexdump -C /path/to/firmware.bin | head -n 100
```

<details>
<summary>eg: a non-encrypted firmware would look something like this with hexdump (Click to expand)</summary>

```text
akm@RHEL:~/Git/Forked/tmp/mimo/fw/latest/out$ hexdump -C 'ax53v1-up-all-ver1-7-3-P1[20260629-rel42519]-1024_sign.bin' | head -n 100
00000000  02 5a 15 1f c8 6f 90 27  31 5a e2 cf ad cb fb 7e  |.Z...o.'1Z.....~|
00000010  36 34 94 47 66 77 2d 74  79 70 65 3a 43 6c 6f 75  |64.Gfw-type:Clou|
00000020  64 0a 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |d...............|
00000030  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
*
00000110  00 00 01 00 aa 55 4c 5e  83 1f 53 4b a1 f8 f7 c9  |.....UL^..SK....|
00000120  18 df 8f bf 7d a1 55 aa  00 00 00 00 00 00 00 00  |....}.U.........|
00000130  58 73 31 da 3d 8e a0 6b  51 6c 9f ca ad 26 60 97  |Xs1.=..kQl...&`.|
00000140  2b 17 a9 f0 94 15 bd ee  dc 0b fa 32 05 3b 2c 17  |+..........2.;,.|
00000150  1b d1 e6 b8 4a 2f a1 61  07 11 8b d0 6d 12 de 42  |....J/.a....m..B|
00000160  43 1a 93 d1 61 5a 86 dc  50 c3 53 89 67 f4 ab f2  |C...aZ..P.S.g...|
00000170  7d 6c 9b e0 94 cf 1c 40  f3 eb 8b 6a f0 24 2f 6e  |}l.....@...j.$/n|
00000180  ea c1 af 59 56 0f 5c f0  e6 34 c2 c1 a3 63 5e 3c  |...YV.\..4...c^<|
00000190  9b 9b 05 dd 7a b7 ed 94  b1 49 cc 57 34 ab f5 e8  |....z....I.W4...|
000001a0  96 d5 e9 75 61 11 70 42  fa 41 9f 7b 4f 98 44 1b  |...ua.pB.A.{O.D.|
000001b0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
*
000001d0  00 00 01 00 aa 55 9d d1  a8 c8 83 31 c9 69 fb bf  |.....U.....1.i..|
000001e0  bc f0 d4 32 70 c7 55 aa  00 00 00 00 00 00 00 00  |...2p.U.........|
000001f0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
*
00000280  7c 8c 71 f6 73 f5 82 ce  a6 6c b1 25 81 3d c3 53  ||.q.s....l.%.=.S|
00000290  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
000002a0  ff ff ff ff ff ff ff ff  ff ff ff ff ff ff ff ff  |................|
*
00001010  ff ff ff ff 73 75 70 70  6f 72 74 2d 6c 69 73 74  |....support-list|
00001020  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
00001030  00 00 00 00 00 00 00 2c  00 00 04 8f 00 00 04 63  |.......,.......c|
00001040  53 75 70 70 6f 72 74 4c  69 73 74 3a 0a 7b 70 72  |SupportList:.{pr|
00001050  6f 64 75 63 74 5f 6e 61  6d 65 3a 41 72 63 68 65  |oduct_name:Arche|
00001060  72 20 41 58 35 33 2c 70  72 6f 64 75 63 74 5f 76  |r AX53,product_v|
00001070  65 72 3a 31 2e 30 2e 30  2c 73 70 65 63 69 61 6c  |er:1.0.0,special|
00001080  5f 69 64 3a 35 35 35 33  30 30 30 30 7d 0a 7b 70  |_id:55530000}.{p|
00001090  72 6f 64 75 63 74 5f 6e  61 6d 65 3a 41 72 63 68  |roduct_name:Arch|
000010a0  65 72 20 41 58 35 33 2c  70 72 6f 64 75 63 74 5f  |er AX53,product_|
000010b0  76 65 72 3a 31 2e 30 2e  30 2c 73 70 65 63 69 61  |ver:1.0.0,specia|
000010c0  6c 5f 69 64 3a 34 35 35  35 30 30 30 30 7d 0a 7b  |l_id:45550000}.{|
000010d0  70 72 6f 64 75 63 74 5f  6e 61 6d 65 3a 41 72 63  |product_name:Arc|
000010e0  68 65 72 20 41 58 35 33  2c 70 72 6f 64 75 63 74  |her AX53,product|
000010f0  5f 76 65 72 3a 31 2e 30  2e 30 2c 73 70 65 63 69  |_ver:1.0.0,speci|
00001100  61 6c 5f 69 64 3a 34 41  35 30 30 30 30 30 7d 0a  |al_id:4A500000}.|
00001110  7b 70 72 6f 64 75 63 74  5f 6e 61 6d 65 3a 41 72  |{product_name:Ar|
00001120  63 68 65 72 20 41 58 35  33 2c 70 72 6f 64 75 63  |cher AX53,produc|
00001130  74 5f 76 65 72 3a 31 2e  30 2e 30 2c 73 70 65 63  |t_ver:1.0.0,spec|
00001140  69 61 6c 5f 69 64 3a 35  32 35 35 30 30 30 30 7d  |ial_id:52550000}|
00001150  0a 7b 70 72 6f 64 75 63  74 5f 6e 61 6d 65 3a 41  |.{product_name:A|
00001160  72 63 68 65 72 20 41 58  35 33 2c 70 72 6f 64 75  |rcher AX53,produ|
00001170  63 74 5f 76 65 72 3a 31  2e 30 2e 30 2c 73 70 65  |ct_ver:1.0.0,spe|
00001180  63 69 61 6c 5f 69 64 3a  35 33 34 37 30 30 30 30  |cial_id:53470000|
00001190  7d 0a 7b 70 72 6f 64 75  63 74 5f 6e 61 6d 65 3a  |}.{product_name:|
000011a0  41 72 63 68 65 72 20 41  58 35 33 2c 70 72 6f 64  |Archer AX53,prod|
000011b0  75 63 74 5f 76 65 72 3a  31 2e 30 2e 30 2c 73 70  |uct_ver:1.0.0,sp|
000011c0  65 63 69 61 6c 5f 69 64  3a 34 42 35 32 30 30 30  |ecial_id:4B52000|
000011d0  30 7d 0a 7b 70 72 6f 64  75 63 74 5f 6e 61 6d 65  |0}.{product_name|
000011e0  3a 41 72 63 68 65 72 20  41 58 35 33 2c 70 72 6f  |:Archer AX53,pro|
000011f0  64 75 63 74 5f 76 65 72  3a 31 2e 30 2e 30 2c 73  |duct_ver:1.0.0,s|
00001200  70 65 63 69 61 6c 5f 69  64 3a 34 35 34 37 30 30  |pecial_id:454700|
00001210  30 30 7d 0a 7b 70 72 6f  64 75 63 74 5f 6e 61 6d  |00}.{product_nam|
00001220  65 3a 41 72 63 68 65 72  20 41 58 35 33 2c 70 72  |e:Archer AX53,pr|
00001230  6f 64 75 63 74 5f 76 65  72 3a 31 2e 30 2e 30 2c  |oduct_ver:1.0.0,|
00001240  73 70 65 63 69 61 6c 5f  69 64 3a 34 32 35 32 30  |special_id:42520|
00001250  30 30 30 7d 0a 7b 70 72  6f 64 75 63 74 5f 6e 61  |000}.{product_na|
00001260  6d 65 3a 41 72 63 68 65  72 20 41 58 35 33 2c 70  |me:Archer AX53,p|
00001270  72 6f 64 75 63 74 5f 76  65 72 3a 31 2e 30 2e 30  |roduct_ver:1.0.0|
00001280  2c 73 70 65 63 69 61 6c  5f 69 64 3a 34 33 34 31  |,special_id:4341|
00001290  30 30 30 30 7d 0a 7b 70  72 6f 64 75 63 74 5f 6e  |0000}.{product_n|
000012a0  61 6d 65 3a 41 72 63 68  65 72 20 41 58 33 30 30  |ame:Archer AX300|
000012b0  30 2c 70 72 6f 64 75 63  74 5f 76 65 72 3a 31 2e  |0,product_ver:1.|
000012c0  30 2e 30 2c 73 70 65 63  69 61 6c 5f 69 64 3a 35  |0.0,special_id:5|
000012d0  32 35 35 30 30 30 30 7d  0a 7b 70 72 6f 64 75 63  |2550000}.{produc|
000012e0  74 5f 6e 61 6d 65 3a 41  72 63 68 65 72 20 41 58  |t_name:Archer AX|
000012f0  35 38 2c 70 72 6f 64 75  63 74 5f 76 65 72 3a 31  |58,product_ver:1|
00001300  2e 30 2e 30 2c 73 70 65  63 69 61 6c 5f 69 64 3a  |.0.0,special_id:|
00001310  34 35 35 35 30 30 30 30  7d 0a 7b 70 72 6f 64 75  |45550000}.{produ|
00001320  63 74 5f 6e 61 6d 65 3a  41 72 63 68 65 72 20 41  |ct_name:Archer A|
00001330  58 35 33 48 50 2c 70 72  6f 64 75 63 74 5f 76 65  |X53HP,product_ve|
00001340  72 3a 31 2e 30 2e 30 2c  73 70 65 63 69 61 6c 5f  |r:1.0.0,special_|
00001350  69 64 3a 35 35 35 33 30  30 30 30 7d 0a 7b 70 72  |id:55530000}.{pr|
00001360  6f 64 75 63 74 5f 6e 61  6d 65 3a 41 72 63 68 65  |oduct_name:Arche|
00001370  72 20 41 58 35 33 48 50  2c 70 72 6f 64 75 63 74  |r AX53HP,product|
00001380  5f 76 65 72 3a 31 2e 30  2e 30 2c 73 70 65 63 69  |_ver:1.0.0,speci|
00001390  61 6c 5f 69 64 3a 34 35  35 35 30 30 30 30 7d 0a  |al_id:45550000}.|
000013a0  7b 70 72 6f 64 75 63 74  5f 6e 61 6d 65 3a 41 72  |{product_name:Ar|
000013b0  63 68 65 72 20 41 58 35  37 2c 70 72 6f 64 75 63  |cher AX57,produc|
000013c0  74 5f 76 65 72 3a 31 2e  30 2e 30 2c 73 70 65 63  |t_ver:1.0.0,spec|
000013d0  69 61 6c 5f 69 64 3a 35  35 35 33 30 30 30 30 7d  |ial_id:55530000}|
000013e0  0a 7b 70 72 6f 64 75 63  74 5f 6e 61 6d 65 3a 41  |.{product_name:A|
000013f0  72 63 68 65 72 20 41 58  35 37 2c 70 72 6f 64 75  |rcher AX57,produ|
00001400  63 74 5f 76 65 72 3a 31  2e 30 2e 30 2c 73 70 65  |ct_ver:1.0.0,spe|
00001410  63 69 61 6c 5f 69 64 3a  34 33 34 31 30 30 30 30  |cial_id:43410000|
00001420  7d 0a 7b 70 72 6f 64 75  63 74 5f 6e 61 6d 65 3a  |}.{product_name:|
00001430  41 72 63 68 65 72 20 41  58 35 36 2c 70 72 6f 64  |Archer AX56,prod|
00001440  75 63 74 5f 76 65 72 3a  31 2e 30 2e 30 2c 73 70  |uct_ver:1.0.0,sp|
00001450  65 63 69 61 6c 5f 69 64  3a 35 35 35 33 30 30 30  |ecial_id:5553000|
00001460  30 7d 0a 7b 70 72 6f 64  75 63 74 5f 6e 61 6d 65  |0}.{product_name|
00001470  3a 41 72 63 68 65 72 20  41 58 35 36 2c 70 72 6f  |:Archer AX56,pro|
00001480  64 75 63 74 5f 76 65 72  3a 31 2e 30 2e 30 2c 73  |duct_ver:1.0.0,s|
00001490  70 65 63 69 61 6c 5f 69  64 3a 34 35 35 35 30 30  |pecial_id:455500|
000014a0  30 30 7d 73 6f 66 74 2d  76 65 72 73 69 6f 6e 00  |00}soft-version.|
000014b0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
```
</details>

<details>
<summary>eg: a encrypted firmware would look something like this with hexdump (Click to expand)</summary>

```text
akm@RHEL:~/Git/Forked/tmp/mimo/fw/latest/out$ hexdump -C 'ax53v1-up-ax53v1-only-ver1-5-5-P1[20251215-rel87654]-2048_sign.bin' | head -n 100
00000000  02 56 13 12 42 df 53 68  b9 bd c4 f2 d1 2d 67 8c  |.V..B.Sh.....-g.|
00000010  96 54 98 ae 66 77 2d 74  79 70 65 3a 43 6c 6f 75  |.T..fw-type:Clou|
00000020  64 0a 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |d...............|
00000030  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
*
00000110  00 00 02 00 aa 55 4c 5e  83 1f 53 4b a1 f8 f7 c9  |.....UL^..SK....|
00000120  18 df 8f bf 7d a1 55 aa  00 00 00 00 00 00 00 00  |....}.U.........|
00000130  c3 02 4f 1d 73 a9 e8 1a  fa 21 d9 d4 b9 2b ee 61  |..O.s....!...+.a|
00000140  8a c0 1b 6a de e5 c4 9c  dc 84 6f 8b 42 2e d6 56  |...j......o.B..V|
00000150  cd 1c 61 a0 6c 59 ab fd  fe e8 f6 9d 8e 3f c8 08  |..a.lY.......?..|
00000160  0b 95 b0 0f 9b ea f8 0a  1b 85 24 af bb e8 ef 78  |..........$....x|
00000170  51 52 3a 96 32 fb e6 f4  29 56 24 d8 2c b3 81 5a  |QR:.2...)V$.,..Z|
00000180  ed aa 06 3f fb 5d c9 09  96 11 0a db f6 22 82 d2  |...?.]......."..|
00000190  6d 05 e8 de f5 09 3f 69  a6 3b 05 d0 66 a0 48 14  |m.....?i.;..f.H.|
000001a0  ee 18 5a ce d7 23 62 9c  a8 38 6a 8d 2e 93 e2 e6  |..Z..#b..8j.....|
000001b0  cc ad 0c 49 6a 76 70 e8  ec f0 8c 02 da 6e cf aa  |...Ijvp......n..|
000001c0  89 f3 96 d0 44 a3 3e 34  f3 22 bc 24 d1 0f cd 98  |....D.>4.".$....|
000001d0  52 81 07 c9 56 33 a9 e8  cb 73 95 b4 c7 bc 5d e6  |R...V3...s....].|
000001e0  91 9f 78 31 3e 14 24 93  64 27 96 2e c3 58 0b 46  |..x1>.$.d'...X.F|
000001f0  7f 35 c4 84 47 a4 37 69  e6 d8 0c 37 31 72 fb 3f  |.5..G.7i...71r.?|
00000200  10 bb 94 81 43 02 4d ce  9c 4d 88 60 53 e2 84 98  |....C.M..M.`S...|
00000210  64 69 6e ca 19 15 10 a2  56 62 06 10 ae a9 fe 60  |din.....Vb.....`|
00000220  69 ea 7f 0b ee 74 da ed  60 3c 87 d1 4f 2f 09 03  |i....t..`<..O/..|
00000230  f9 1e 4b 5a 7b ea 0a cf  d1 bb 06 72 90 92 ee 0c  |..KZ{......r....|
00000240  7c 6d df 9e 9f 2b 20 10  e1 25 5d e9 92 a2 1b b4  ||m...+ ..%].....|
00000250  59 27 52 a5 45 9e d5 44  88 82 cb ad 65 5c f9 e0  |Y'R.E..D....e\..|
00000260  bd df 9b 5a aa 1e 0d 76  0f aa 38 4a 07 06 24 7b  |...Z...v..8J..${|
00000270  e7 e2 3b f7 00 0b b4 5f  dd 35 38 01 ea bd ba 39  |..;...._.58....9|
00000280  86 b8 c2 d1 bd c5 d8 26  78 01 c6 47 8d 51 1a 8d  |.......&x..G.Q..|
00000290  63 49 f9 12 e6 45 f8 73  06 1f 8f df e1 af 28 6a  |cI...E.s......(j|
000002a0  10 5b af 0a d9 22 26 55  b9 9c b1 ba 00 e4 1e 6b  |.[..."&U.......k|
000002b0  a0 6f 9e 5c 7c 92 7b 9b  0e 33 ab 1d c6 a0 69 26  |.o.\|.{..3....i&|
000002c0  5e 40 33 ea 1e 42 bb 3a  ff 1f 53 59 25 a7 1e 8e  |^@3..B.:..SY%...|
000002d0  a0 58 7a eb cd 49 12 77  53 6b e0 b2 c4 df 80 c9  |.Xz..I.wSk......|
000002e0  2a 86 ac d2 e1 a7 3b ed  00 bf bc 5c 9b 02 36 91  |*.....;....\..6.|
000002f0  5b 04 d7 cd cd 18 df c0  0c 89 f3 83 c5 31 8b 72  |[............1.r|
00000300  4d 7e 7e cd fc 7b 7b d3  0a 11 bd 55 54 2d f3 29  |M~~..{{....UT-.)|
00000310  51 ec 21 66 a2 ef 4c 6c  2c 9f 16 83 7f 1f 73 a8  |Q.!f..Ll,.....s.|
00000320  a1 c1 40 3c 39 f4 22 34  f3 4a 15 97 1f 49 4c 53  |..@<9."4.J...ILS|
00000330  3a ba 38 c8 82 4b 3e 9a  bb 36 48 27 89 19 c0 a4  |:.8..K>..6H'....|
00000340  6a c9 ed 6a 2c 6a 1d a7  7d 07 3d 70 65 15 be 7f  |j..j,j..}.=pe...|
00000350  a2 85 f5 2e fb d3 1e 21  6a 68 c6 ad 08 b8 d7 60  |.......!jh.....`|
00000360  17 0e d8 f8 fe a3 24 71  7e cd 87 d4 eb cc 6c 7c  |......$q~.....l||
00000370  40 89 81 83 3b df 88 40  cc 38 c4 8d c3 fe cb d6  |@...;..@.8......|
00000380  ac 00 a9 5c 25 b5 db 96  60 51 e2 51 b0 8f b6 5f  |...\%...`Q.Q..._|
00000390  7f 21 38 8a fd 8d 27 fa  51 92 16 65 db eb 0c 38  |.!8...'.Q..e...8|
000003a0  aa c4 86 fe 8d eb 8f 51  94 c3 49 6f cd 48 84 27  |.......Q..Io.H.'|
000003b0  2c 19 23 12 02 c4 17 4b  6b 3c 37 7f 8d bb a9 fd  |,.#....Kk<7.....|
000003c0  c3 25 e7 3a 75 a6 e3 41  33 01 db 2e b6 be 1f 76  |.%.:u..A3......v|
000003d0  cd 3b 6f 67 25 cc bb 09  55 b1 4b 5e 84 62 2a 7c  |.;og%...U.K^.b*||
000003e0  ec e9 91 6c b4 5a 1b 05  53 57 7e 9f f6 00 76 c2  |...l.Z..SW~...v.|
000003f0  38 af aa 2b e4 70 a7 f8  09 d7 d8 46 d6 1b 4a b1  |8..+.p.....F..J.|
00000400  e9 a7 80 3a 0f 77 4f 1b  8f e0 b1 2e 37 88 b2 cb  |...:.wO.....7...|
00000410  52 4f 9b a0 a5 9f e1 34  c9 fb 3c 75 93 f7 1b e9  |RO.....4..<u....|
00000420  19 a6 bc 16 17 3d 64 97  09 ca 69 a8 5f 36 f5 bd  |.....=d...i._6..|
00000430  8c a7 c9 93 20 95 16 de  cd 81 d5 cc 00 81 8b e1  |.... ...........|
00000440  d6 b7 f9 8a 3e 65 39 27  dc d0 44 0c 21 5c 76 8f  |....>e9'..D.!\v.|
00000450  c9 dd ba 63 89 dd a9 30  25 d3 df dc 0e b9 48 52  |...c...0%.....HR|
00000460  fb b5 05 fd 74 e1 48 78  52 c1 df 82 11 df d9 9d  |....t.HxR.......|
00000470  c0 b7 08 a2 41 ac 10 61  74 fa 4c 67 87 3c 4e 21  |....A..at.Lg.<N!|
00000480  d7 52 47 5d 6e a5 b0 15  19 95 e0 1a 79 a6 b7 86  |.RG]n.......y...|
00000490  8c e9 64 43 6a e4 69 0f  fc a2 58 6a 40 39 b6 3b  |..dCj.i...Xj@9.;|
000004a0  16 41 10 cb e6 59 d3 9e  43 d1 28 50 23 88 9b 93  |.A...Y..C.(P#...|
000004b0  cb de b0 c3 40 88 c8 33  8e 19 09 f9 6c 28 91 f3  |....@..3....l(..|
000004c0  26 7c dc df 9c 3e a0 7c  ba b6 06 b1 55 99 53 01  |&|...>.|....U.S.|
000004d0  c0 37 f2 eb 65 d2 70 e3  ef 75 c4 f8 88 02 f8 84  |.7..e.p..u......|
000004e0  38 a2 db fe fa 4b a8 cf  f9 d6 d8 6e 6c 08 dd 43  |8....K.....nl..C|
000004f0  f5 ca 00 ae dc e1 f5 d3  7c 55 05 ae 2e eb 44 55  |........|U....DU|
00000500  ce d1 d8 22 6a c6 b5 fb  24 07 27 1b 5f ea 73 06  |..."j...$.'._.s.|
00000510  e4 08 31 2c 35 71 81 6b  0f 60 54 d6 ee 51 46 54  |..1,5q.k.`T..QFT|
00000520  eb d3 dd 63 82 52 59 4e  26 24 c6 c9 bb 9a 59 ad  |...c.RYN&$....Y.|
00000530  85 f3 92 4b 85 22 08 c1  a6 5c 7c 17 36 5b 58 1b  |...K."...\|.6[X.|
00000540  3b 9b f1 94 77 82 52 e7  50 c6 0c c5 d8 96 03 65  |;...w.R.P......e|
00000550  0d 7d e4 da a4 c2 26 48  eb 7f e1 65 6c c6 4b 1a  |.}....&H...el.K.|
00000560  3a bd d9 ef cf ef 9e 54  20 8e de 03 c8 98 94 6c  |:......T ......l|
00000570  e3 0e 28 c8 25 4c 97 70  8e 4b e8 00 45 8f 4e 54  |..(.%L.p.K..E.NT|
00000580  1f 2b 3d e2 4b 31 40 86  d9 54 3b af 82 be 66 0a  |.+=.K1@..T;...f.|
00000590  40 01 77 ea dd 47 18 78  23 aa ae 49 bb 1b 73 95  |@.w..G.x#..I..s.|
000005a0  78 e8 79 0d af 60 15 3a  ed 2c c1 79 5b c0 7e 47  |x.y..`.:.,.y[.~G|
000005b0  82 f6 b4 ad 52 fc ca 1a  a2 f0 84 fe ed 0e 4e 75  |....R.........Nu|
000005c0  68 97 78 ed 60 da 37 47  3a 60 7c 28 9f b0 fa 66  |h.x.`.7G:`|(...f|
000005d0  ba eb 4b 9e 5d fe e9 8e  3c 3a 8b e2 31 c4 06 55  |..K.]...<:..1..U|
000005e0  63 64 94 bd bd 5d 5d 8d  0e 2d c0 ac a5 46 40 2a  |cd...]]..-...F@*|
000005f0  e8 04 8a 6d ba d7 d7 62  df 40 c3 9d 3c ab 89 d5  |...m...b.@..<...|
00000600  5c 7e d1 bb ca 90 0f 74  99 6c 2d bb 3e 55 4c 51  |\~.....t.l-.>ULQ|
00000610  d0 4e f2 f0 f6 2f 28 d9  ae 24 d8 69 23 92 6e 84  |.N.../(..$.i#.n.|
00000620  00 1f 54 f6 51 b1 6b fe  b6 65 9d 8a fa 23 e3 ad  |..T.Q.k..e...#..|
00000630  8a 8b 0f a4 0d c2 2b f5  1e 5d d8 bc 64 d5 37 75  |......+..]..d.7u|
00000640  8c 19 82 c8 6a 45 ff 03  bc e7 b5 9b 65 d3 e5 92  |....jE......e...|
00000650  31 ea 7e b3 3f 6c b8 5f  c2 31 50 e1 50 34 31 da  |1.~.?l._.1P.P41.|
00000660  96 83 dc 26 ac 82 a1 fe  4a a1 a4 4e f8 08 b8 b5  |...&....J..N....|
00000670  bc dc fb c6 6d 94 1d c6  7e ce f4 b2 9f 82 68 09  |....m...~.....h.|
00000680  1c cc 9e b7 0d 11 bf a8  ea 0c f0 09 9f bf 9c 9c  |................|
00000690  a0 f2 3b e2 17 92 58 22  82 2a 12 e6 3f c4 6f 05  |..;...X".*..?.o.|
000006a0  60 4c 49 c6 cd 1f cc a2  f2 5d 9a 72 80 71 59 e2  |`LI......].r.qY.|
000006b0  8e ad b2 ba 1e b7 dc 23  58 22 54 9f 65 da 46 c5  |.......#X"T.e.F.|
000006c0  e5 d2 66 80 8a e9 17 12  62 b4 ee 31 66 ef 07 53  |..f.....b..1f..S|
000006d0  7e 4f cc 36 7b 9f d0 10  07 ba e6 01 38 7e 89 01  |~O.6{.......8~..|
000006e0  da a4 eb 3b 51 99 08 51  5f 10 1e 33 ba c8 dc 4c  |...;Q..Q_..3...L|
000006f0  68 22 85 39 26 24 45 9a  d1 71 09 8e 33 62 4e 73  |h".9&$E..q..3bNs|
```

</details>

Another way of verifying if a firmware is encrypted or not is by using binwalk
```plaintext
# Command
binwalk /path/to/firmware
```
<details>
<summary>eg: a non encrypted firmware would look something like this with binwalk (Click to expand)</summary>

```text
akm@RHEL:~/Git/Forked/tmp/mimo/fw/latest/out$ binwalk 'ax53v1-up-ax53v1-only-ver1-7-1-P1[20260213-rel87654]-2048_sign_decrypted.bin'

/home/akm/Git/Forked/tmp/mimo/fw/latest/out/ax53v1-up-ax53v1-only-ver1-7-1-P1[20260213-rel87654]-2048_sign_decrypted.bin
----------------------------------------------------------------------------------------------------
DECIMAL                            HEXADECIMAL                        DESCRIPTION
----------------------------------------------------------------------------------------------------
4882                               0x1312                             UBI image, version: 1, image 
                                                                      size: 39452672 bytes
----------------------------------------------------------------------------------------------------

Analyzed 1 file for 85 file signatures (187 magic patterns) in 168.0 milliseconds
```

</details>

<details>
<summary>eg: a encrypted firmware would look something like this with binwalk (Click to expand)</summary>

```text
akm@RHEL:~/Git/Forked/tmp/mimo/fw/latest/out$ binwalk 'ax53v1-up-ax53v1-only-ver1-7-1-P1[20260213-rel87654]-2048_sign.bin'
Analyzed 1 file for 85 file signatures (187 magic patterns) in 444.0 milliseconds
```

</details>

### Usage
To use the RSA_FW_Decrypter, clone this repo then from root of this repo, `cd RSA_FW_Decrypt` then run the `decrypt_fw.sh` script.
```plaintext
./decrypt_fw.sh <'/path/to/encrypted_fw.bin'>  <optional out dir> 
```
If no output directory is specified, the script will save the decrypted firmware in the same directory as the source file. Note: The script requires sudo privileges to set up the chroot environment; please provide your password when prompted.

```plaintext
# deps needed by the script.
sudo apt update && sudo apt install -y coreutils tar sudo gawk util-linux
```
<details>
<summary>Full Decryption log log</summary>

```text
akm@RHEL:~/Git/Forked/tp-link-ax55-fw-hacks$ cd RSA_FW_Decrypt
akm@RHEL:~/Git/Forked/tp-link-ax55-fw-hacks/RSA_FW_Decrypt$ ls
chroot.tar.gz  decrypt_fw.sh  qemu-arm-static
akm@RHEL:~/Git/Forked/tp-link-ax55-fw-hacks/RSA_FW_Decrypt$ ./decrypt_fw.sh '/home/akm/Git/Forked/tmp/Archer AX55_V1_251119/ax55v1-up-all-ver1-5-11-P1[20251119-rel49503]-2048_nosign_2025-11-19_21.03.44.bin' 

======================================
Checking Paths
======================================

[*] Defined Paths ...
 ├─ Source: /home/akm/Git/Forked/tmp/Archer AX55_V1_251119/ax55v1-up-all-ver1-5-11-P1[20251119-rel49503]-2048_nosign_2025-11-19_21.03.44.bin
 └─ Target: /home/akm/Git/Forked/tmp/Archer AX55_V1_251119/ax55v1-up-all-ver1-5-11-P1[20251119-rel49503]-2048_nosign_2025-11-19_21.03.44_decrypted.bin


======================================
Extracting and setting up chroot ...
======================================

[*] Extracting chroot environment from archive (sudo, preserving perms)...
[sudo] password for akm: 
[*] Copying qemu-arm-static into chroot...
[*] Staging firmware and setting hard-link trap...

======================================
Hex dump of header before decryption:
======================================

[*] Hexdump preview (encrypted input, first 100 lines): /home/akm/Git/Forked/tmp/Archer AX55_V1_251119/ax55v1-up-all-ver1-5-11-P1[20251119-rel49503]-2048_nosign_2025-11-19_21.03.44.bin
--------------------------------------------------------------------
00000000  02 56 12 90 2f 74 6d d5  f4 62 d5 11 f0 73 fc 40  |.V../tm..b...s.@|
00000010  f6 d5 dc 90 66 77 2d 74  79 70 65 3a 43 6c 6f 75  |....fw-type:Clou|
00000020  64 0a 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |d...............|
00000030  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
*
00000110  00 00 02 00 aa 55 4c 5e  83 1f 53 4b a1 f8 f7 c9  |.....UL^..SK....|
00000120  18 df 8f bf 7d a1 55 aa  00 00 00 00 00 00 00 00  |....}.U.........|
00000130  5d a0 27 ea 4d e9 57 e4  8c aa 6a e0 86 4d b1 97  |].'.M.W...j..M..|
00000140  4b 8b 9e 8b ff 06 46 79  a6 10 56 69 75 b5 b1 55  |K.....Fy..Viu..U|
00000150  00 5f 0b 6f 90 f8 b8 74  0b 59 6d 13 75 f0 04 18  |._.o...t.Ym.u...|
00000160  76 6a 75 c0 f2 b5 c5 66  70 da 8b 8e aa 8e 5b e7  |vju....fp.....[.|
00000170  88 db f5 ed 8c 52 ad ed  3c fe 57 f2 83 87 b8 a1  |.....R..<.W.....|
00000180  cc e5 79 26 9d a3 ba 67  e5 0b 9a e6 65 ea 27 a1  |..y&...g....e.'.|
00000190  40 89 06 62 18 12 89 68  1a 0e c5 c9 59 5b 4a ac  |@..b...h....Y[J.|
000001a0  5b fd 9d b3 ac eb 96 bb  73 16 b2 63 f9 dc 09 f7  |[.......s..c....|
000001b0  7b 2b 9d 88 ae a2 b6 ff  86 66 07 23 6e 52 83 b6  |{+.......f.#nR..|
000001c0  8a a7 a2 21 5b e4 77 ae  89 8f 8c 24 f3 c6 ab 46  |...![.w....$...F|
000001d0  d8 af f1 6e 04 20 df 93  eb b3 7e b2 d1 e8 f1 af  |...n. ....~.....|
000001e0  f7 fc b7 09 2d 5f c2 24  02 92 20 5a 8e 9c b7 d5  |....-_.$.. Z....|
000001f0  4c 95 2f 86 bc c8 bb 09  35 af c5 b7 74 3d 0d 78  |L./.....5...t=.x|
00000200  0a 57 37 dc 6d a7 7f 76  fe 37 fa 09 e6 01 6b a0  |.W7.m..v.7....k.|
00000210  1a 75 e9 aa 85 73 ff 2f  06 1b 51 ee 0f ef 2e 66  |.u...s./..Q....f|
00000220  35 7a f5 ec 92 b7 6c fb  06 b4 a1 f6 62 93 89 01  |5z....l.....b...|
00000230  f7 30 b8 01 70 c4 14 09  fd 6b 87 a4 dc af 60 b6  |.0..p....k....`.|
00000240  65 a8 39 ea b2 3d bb 89  3a 5e bc 68 13 c2 d9 ea  |e.9..=..:^.h....|
00000250  5c a1 89 34 15 01 83 59  2f c7 3b e0 74 ee 22 5a  |\..4...Y/.;.t."Z|
00000260  ad b3 a5 9f a7 f8 27 b1  bd cd e6 c9 b7 62 fa ba  |......'......b..|
00000270  a0 70 d7 00 10 0a 72 73  82 19 ea 4d 1f 3d 21 52  |.p....rs...M.=!R|
00000280  e8 34 94 19 dd 68 a5 7c  a6 8c 9d 27 4b 34 dc a7  |.4...h.|...'K4..|
00000290  52 8e 01 5a 29 d1 85 86  1b 24 37 03 65 1e 9b 0f  |R..Z)....$7.e...|
000002a0  00 ad b9 61 b8 5c b0 85  5e d1 45 86 d4 1b 5e 6d  |...a.\..^.E...^m|
000002b0  ea c4 b1 00 f4 b0 89 07  fc 16 36 81 e1 d4 2f 24  |..........6.../$|
000002c0  97 0c 8f 52 d4 62 01 97  4e 0d fc 9f f5 cd f7 63  |...R.b..N......c|
000002d0  f9 e5 f9 42 1f 39 af 0c  bf fe 49 6d 99 76 70 e5  |...B.9....Im.vp.|
000002e0  df 61 96 c7 d6 1a ff fe  8d 55 d3 09 a8 ee a5 d7  |.a.......U......|
000002f0  dc d1 9c f6 f3 ba f5 d2  13 1e 64 42 0f 96 42 75  |..........dB..Bu|
00000300  66 a3 12 7d 34 cd 8d 7a  1b b7 98 ff 68 6e 15 22  |f..}4..z....hn."|
00000310  cc bd 08 68 ed 47 d4 ca  75 69 da fa 20 ec d9 99  |...h.G..ui.. ...|
00000320  db 28 8e 99 a9 7f 55 ae  7b 64 e9 e3 50 61 3b 94  |.(....U.{d..Pa;.|
00000330  1e 7d 8a 44 f3 d0 97 71  7e ca e5 6f 65 fc 0d 62  |.}.D...q~..oe..b|
00000340  50 cd a6 33 63 9a 67 ea  31 63 82 32 86 6e 50 e4  |P..3c.g.1c.2.nP.|
00000350  84 aa 16 56 f2 15 2b e8  4a 0f ed 1d 45 1d f5 02  |...V..+.J...E...|
00000360  27 1b 01 0b 7c 36 4a 4d  2b 39 3c 64 fe 7a 58 3b  |'...|6JM+9<d.zX;|
00000370  ce 1f 90 68 2b fe 0f 27  33 ff 81 71 b7 a8 3f aa  |...h+..'3..q..?.|
00000380  65 54 b0 e4 64 3f 6f 4a  41 cf e4 a3 17 6f 18 1b  |eT..d?oJA....o..|
00000390  6c 0f 41 21 fa 43 29 c2  1c 40 5e 57 11 e7 16 fb  |l.A!.C)..@^W....|
000003a0  d0 df ed 88 13 a2 3d f6  fb c5 31 42 4e 4f c8 48  |......=...1BNO.H|
000003b0  db 8d f6 41 80 b7 a7 6a  a3 28 28 77 87 bb 28 b6  |...A...j.((w..(.|
000003c0  b2 a2 95 a6 5b 77 56 a3  6e 1e 80 db 86 05 fc 11  |....[wV.n.......|
000003d0  65 d1 1d 43 4b 53 49 82  b4 66 e8 8d b8 5b 12 6a  |e..CKSI..f...[.j|
000003e0  ea e6 9b f3 1e 9f 74 55  db 43 0f 7a 11 f3 eb fc  |......tU.C.z....|
000003f0  cc 22 9e 03 4b ec 44 4e  6d e3 d7 80 7e 39 be c3  |."..K.DNm...~9..|
00000400  99 8b 9f 75 46 34 bd 74  41 f6 30 07 cb af 01 a3  |...uF4.tA.0.....|
00000410  98 b5 93 43 83 b9 05 15  05 14 80 5a 3f d0 a0 a4  |...C.......Z?...|
00000420  83 58 44 5e 31 d6 b4 8d  2f 55 32 54 66 e6 c9 57  |.XD^1.../U2Tf..W|
00000430  af d3 65 34 cc 8f 17 26  4d 1f ff ed 53 cc 40 cb  |..e4...&M...S.@.|
00000440  5f f3 42 a4 0b 43 5d 85  13 8c a1 7a b3 93 6b 0d  |_.B..C]....z..k.|
00000450  e8 e7 d3 a3 14 9d 96 14  95 4e 41 0e 7a 4e 76 c1  |.........NA.zNv.|
00000460  84 78 4d a2 bc 34 09 60  83 49 4a 2c 4b 90 32 b2  |.xM..4.`.IJ,K.2.|
00000470  52 98 5f 7d 79 9e 10 07  96 75 f5 55 64 53 de 03  |R._}y....u.UdS..|
00000480  d9 69 b5 8a 12 99 5c cf  9b 94 fa ac 76 08 15 04  |.i....\.....v...|
00000490  8d d7 bb d7 ba df 42 8a  3b 18 74 cd 8f 4b f8 4b  |......B.;.t..K.K|
000004a0  0e 95 66 20 a0 2a 28 38  cb 31 87 2e ac b2 be 88  |..f .*(8.1......|
000004b0  a2 9e 98 4e 3c c5 9a 46  ae 91 56 73 bf 19 1d cd  |...N<..F..Vs....|
000004c0  57 d6 ff 47 32 b6 d6 8d  be 88 4b 67 ba db 2a d5  |W..G2.....Kg..*.|
000004d0  30 b5 80 58 dc 0b 98 8e  22 89 e9 60 8c ce 44 88  |0..X...."..`..D.|
000004e0  77 82 80 5b b4 6d 9b 1a  00 09 5b b6 2b 1b 8f 7e  |w..[.m....[.+..~|
000004f0  1a 02 ec 7b 77 a3 ba 79  9f 1b 86 04 38 06 5d 63  |...{w..y....8.]c|
00000500  ea 5a 6c 2e 63 db 7b 05  8b 18 72 77 18 ad 02 8c  |.Zl.c.{...rw....|
00000510  16 19 ff 6b bc c2 d7 68  ec 94 2c 54 c5 c8 b6 5d  |...k...h..,T...]|
00000520  bb df 7d 37 0e 90 5f f5  9f ce 9c 76 4c 2e b4 64  |..}7.._....vL..d|
00000530  f6 94 20 87 7c af 7b aa  5f 19 42 01 b8 85 b9 7b  |.. .|.{._.B....{|
00000540  98 57 66 ae c8 66 56 16  dd 26 5f 21 32 c8 4e c9  |.Wf..fV..&_!2.N.|
00000550  f7 fb e5 18 b8 b4 42 eb  a7 d1 fe d1 dc a0 f0 2f  |......B......../|
00000560  a4 b6 2c 20 95 e5 bb 54  ab 6e 26 7c 28 55 6d 22  |.., ...T.n&|(Um"|
00000570  db 73 29 d4 82 ab 86 d8  b8 f8 21 a1 a9 9e 8c db  |.s).......!.....|
00000580  c7 51 5d 72 7d 64 8e 63  89 15 b3 74 60 3e 3f 6d  |.Q]r}d.c...t`>?m|
00000590  f6 fd 0b f4 c0 66 5a bb  89 f2 ea 6d c0 72 a9 78  |.....fZ....m.r.x|
000005a0  3a a5 47 3c 24 9f f3 5e  e3 9a 5b 7e bf 50 41 76  |:.G<$..^..[~.PAv|
000005b0  b7 3c a0 a9 33 46 e1 cf  8f af 7f 2d 69 86 a1 64  |.<..3F.....-i..d|
000005c0  7a 99 4a 58 6a 9b d1 74  76 0c 0a d8 73 ad a0 4c  |z.JXj..tv...s..L|
000005d0  d6 6d 25 76 24 3a ec f5  99 f7 85 4b 76 87 a8 21  |.m%v$:.....Kv..!|
000005e0  fb b0 27 ba ac 66 a9 d7  69 97 f0 e6 6e 17 0c 10  |..'..f..i...n...|
000005f0  e6 70 bf 39 8b ba bd ce  ed 2f 43 09 e8 b4 2a 58  |.p.9...../C...*X|
00000600  ea 42 68 4d 74 0c 8a 45  78 ae f5 8b 40 43 86 d4  |.BhMt..Ex...@C..|
00000610  fa d4 c2 fe 14 ab 59 65  fc 44 fe 99 32 60 cc 03  |......Ye.D..2`..|
00000620  7e 32 f8 a0 69 05 99 0f  43 f9 ac 2e 9a a2 2d 8a  |~2..i...C.....-.|
00000630  26 28 f1 12 fe ec 08 f2  f1 e6 69 3d 1b 1b 1c 03  |&(........i=....|
00000640  24 64 0c a8 fd 24 9a 0b  a5 89 c7 b2 a6 95 17 82  |$d...$..........|
00000650  1d c1 6d 3b 92 bf 66 ba  53 ba 63 9b a8 6a 43 e1  |..m;..f.S.c..jC.|
00000660  4d 89 b7 6d 45 03 f6 55  74 f5 6c d8 07 0b d3 ae  |M..mE..Ut.l.....|
00000670  b5 4e 0a 32 61 68 9f 1e  c0 62 6f 21 05 aa 4c 7f  |.N.2ah...bo!..L.|
00000680  be 33 7d a8 9e cd 42 4d  12 54 2a 41 dd 98 3f 37  |.3}...BM.T*A..?7|
00000690  46 19 77 84 1c ed e8 4b  3e 8e a4 38 ae 99 7f 06  |F.w....K>..8....|
000006a0  cf 32 3c 99 2d d0 20 03  bd 83 80 c6 bd f4 a9 6c  |.2<.-. ........l|
000006b0  d2 8c 63 44 f5 dd 03 3a  24 ba d8 0f 5b d2 74 93  |..cD...:$...[.t.|
000006c0  55 aa b1 70 7a fe 27 d0  aa 49 40 11 f3 7f 29 35  |U..pz.'..I@...)5|
000006d0  ea b0 fb 88 3e 7c 52 3e  d3 7a 95 93 cd a8 ef 4c  |....>|R>.z.....L|
000006e0  fa 5a aa 3e 46 56 7f 40  1f cc 67 f9 77 9d b8 52  |.Z.>FV.@..g.w..R|
000006f0  49 3d ee 7b e5 ca 12 c3  23 c9 ca 08 53 ef 60 b5  |I=.{....#...S.`.|
--------------------------------------------------------------------


======================================
Decrypting ...
======================================

[*] Executing native ARM decryption via kernel chroot...
--------------------------------------------------------------------

[CheckUpgradeFile, 283]: check firmware.
fw_type_name : Cloud 
[handle_fw_cloud, 104]: RSA2048 PSS
sizeof signbuf 256
md5 or cloud-func verify ok!
[NM_Error](nm_api_readPtnFromBuf) 00985: check: support-list
read from inner size is 276
[Error]sysmgr_proinfo_buildStruct():  670 @ unknown id(device_name), skip it.
[Error]sysmgr_proinfo_buildStruct():  670 @ unknown id(country), skip it.
[Error]sysmgr_proinfo_buildStruct():  670 @ unknown id(hw_ver), skip it.
--------------------------------------------------------------------
      vendorName : TP-Link
       vendorUrl : www.tp-link.com
     productName : Archer AX53
 productLanguage : 
       productId : 30003001
      productVer : ff010000
       specialId : 45550000
            hwId : B8A21A250D06358193A839AAFE53DB78
           oemId : 33407C629E68ACD6503BFE6D4A596762
--------------------------------------------------------------------
[Error]sysmgr_cfg_checkSupportList():  936 @ productName Archer AX55 NOT Match.
[Error]sysmgr_cfg_checkSupportList():  862 @ Entry 0 NOT Match.
[Error]sysmgr_cfg_checkSupportList():  936 @ productName Archer AX55 NOT Match.
[Error]sysmgr_cfg_checkSupportList():  862 @ Entry 1 NOT Match.
[Error]sysmgr_cfg_checkSupportList():  936 @ productName Archer AX55 NOT Match.
[Error]sysmgr_cfg_checkSupportList():  862 @ Entry 2 NOT Match.
[Error]sysmgr_cfg_checkSupportList():  936 @ productName Archer AX55 NOT Match.
[Error]sysmgr_cfg_checkSupportList():  862 @ Entry 3 NOT Match.
[Error]sysmgr_cfg_checkSupportList():  936 @ productName Archer AX55 NOT Match.
[Error]sysmgr_cfg_checkSupportList():  862 @ Entry 4 NOT Match.
[Error]sysmgr_cfg_checkSupportList():  936 @ productName Archer AX55 NOT Match.
[Error]sysmgr_cfg_checkSupportList():  862 @ Entry 5 NOT Match.
[Error]sysmgr_cfg_checkSupportList():  936 @ productName Archer AX55 NOT Match.
[Error]sysmgr_cfg_checkSupportList():  862 @ Entry 6 NOT Match.
Firmwave not supports, check failed.
[NM_Error](nm_buildUpgradeStruct) 01377: Check support list fail.
check firmware error!
[NM_Error](nvrammanager_checkUpgradeFile) 00836: check firmware file failed!

[NM_Error](main) 01214: firmware upgrade file check error 

--------------------------------------------------------------------

[*] nvrammanager exit code: 255 (ignored -- a nonzero/crashed exit here is
    expected on hardware/model mismatch and does not affect the outcome below;
    what matters is whether a firmware file actually got produced.)

[✔] Hard-link trap survived! fetching payload...

[✔] Firmware file produced: /home/akm/Git/Forked/tmp/Archer AX55_V1_251119/ax55v1-up-all-ver1-5-11-P1[20251119-rel49503]-2048_nosign_2025-11-19_21.03.44_decrypted.bin (39195280 bytes)

======================================
Hexdump of header after Decryption:
======================================


[*] Hexdump preview (decrypted output, first 100 lines): /home/akm/Git/Forked/tmp/Archer AX55_V1_251119/ax55v1-up-all-ver1-5-11-P1[20251119-rel49503]-2048_nosign_2025-11-19_21.03.44_decrypted.bin
--------------------------------------------------------------------
00000000  02 56 12 90 2f 74 6d d5  f4 62 d5 11 f0 73 fc 40  |.V../tm..b...s.@|
00000010  f6 d5 dc 90 66 77 2d 74  79 70 65 3a 43 6c 6f 75  |....fw-type:Clou|
00000020  64 0a 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |d...............|
00000030  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
*
00000110  00 00 02 00 aa 55 4c 5e  83 1f 53 4b a1 f8 f7 c9  |.....UL^..SK....|
00000120  18 df 8f bf 7d a1 55 aa  00 00 00 00 00 00 00 00  |....}.U.........|
00000130  5d a0 27 ea 4d e9 57 e4  8c aa 6a e0 86 4d b1 97  |].'.M.W...j..M..|
00000140  4b 8b 9e 8b ff 06 46 79  a6 10 56 69 75 b5 b1 55  |K.....Fy..Viu..U|
00000150  00 5f 0b 6f 90 f8 b8 74  0b 59 6d 13 75 f0 04 18  |._.o...t.Ym.u...|
00000160  76 6a 75 c0 f2 b5 c5 66  70 da 8b 8e aa 8e 5b e7  |vju....fp.....[.|
00000170  88 db f5 ed 8c 52 ad ed  3c fe 57 f2 83 87 b8 a1  |.....R..<.W.....|
00000180  cc e5 79 26 9d a3 ba 67  e5 0b 9a e6 65 ea 27 a1  |..y&...g....e.'.|
00000190  40 89 06 62 18 12 89 68  1a 0e c5 c9 59 5b 4a ac  |@..b...h....Y[J.|
000001a0  5b fd 9d b3 ac eb 96 bb  73 16 b2 63 f9 dc 09 f7  |[.......s..c....|
000001b0  7b 2b 9d 88 ae a2 b6 ff  86 66 07 23 6e 52 83 b6  |{+.......f.#nR..|
000001c0  8a a7 a2 21 5b e4 77 ae  89 8f 8c 24 f3 c6 ab 46  |...![.w....$...F|
000001d0  d8 af f1 6e 04 20 df 93  eb b3 7e b2 d1 e8 f1 af  |...n. ....~.....|
000001e0  f7 fc b7 09 2d 5f c2 24  02 92 20 5a 8e 9c b7 d5  |....-_.$.. Z....|
000001f0  4c 95 2f 86 bc c8 bb 09  35 af c5 b7 74 3d 0d 78  |L./.....5...t=.x|
00000200  0a 57 37 dc 6d a7 7f 76  fe 37 fa 09 e6 01 6b a0  |.W7.m..v.7....k.|
00000210  1a 75 e9 aa 85 73 ff 2f  06 1b 51 ee 0f ef 2e 66  |.u...s./..Q....f|
00000220  35 7a f5 ec 92 b7 6c fb  06 b4 a1 f6 62 93 89 01  |5z....l.....b...|
00000230  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
*
00000250  00 00 01 00 aa 55 9d d1  a8 c8 83 31 c9 69 fb bf  |.....U.....1.i..|
00000260  bc f0 d4 32 70 c7 55 aa  00 00 00 00 00 00 00 00  |...2p.U.........|
00000270  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
*
00000300  a7 f6 7a e1 7b 8a 8c aa  9a d9 98 18 ae 3a 5a a3  |..z.{........:Z.|
00000310  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
00000320  ff ff ff ff ff ff ff ff  ff ff ff ff ff ff ff ff  |................|
*
00001010  ff ff ff ff 73 75 70 70  6f 72 74 2d 6c 69 73 74  |....support-list|
00001020  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
00001030  00 00 00 00 00 00 00 2c  00 00 01 ff 00 00 01 d3  |.......,........|
00001040  53 75 70 70 6f 72 74 4c  69 73 74 3a 0a 7b 70 72  |SupportList:.{pr|
00001050  6f 64 75 63 74 5f 6e 61  6d 65 3a 41 72 63 68 65  |oduct_name:Arche|
00001060  72 20 41 58 35 35 2c 70  72 6f 64 75 63 74 5f 76  |r AX55,product_v|
00001070  65 72 3a 31 2e 30 2e 30  2c 73 70 65 63 69 61 6c  |er:1.0.0,special|
00001080  5f 69 64 3a 35 35 35 33  30 30 30 30 7d 0a 7b 70  |_id:55530000}.{p|
00001090  72 6f 64 75 63 74 5f 6e  61 6d 65 3a 41 72 63 68  |roduct_name:Arch|
000010a0  65 72 20 41 58 35 35 2c  70 72 6f 64 75 63 74 5f  |er AX55,product_|
000010b0  76 65 72 3a 31 2e 30 2e  30 2c 73 70 65 63 69 61  |ver:1.0.0,specia|
000010c0  6c 5f 69 64 3a 34 35 35  35 30 30 30 30 7d 0a 7b  |l_id:45550000}.{|
000010d0  70 72 6f 64 75 63 74 5f  6e 61 6d 65 3a 41 72 63  |product_name:Arc|
000010e0  68 65 72 20 41 58 35 35  2c 70 72 6f 64 75 63 74  |her AX55,product|
000010f0  5f 76 65 72 3a 31 2e 30  2e 30 2c 73 70 65 63 69  |_ver:1.0.0,speci|
00001100  61 6c 5f 69 64 3a 34 33  34 31 30 30 30 30 7d 0a  |al_id:43410000}.|
00001110  7b 70 72 6f 64 75 63 74  5f 6e 61 6d 65 3a 41 72  |{product_name:Ar|
00001120  63 68 65 72 20 41 58 35  35 2c 70 72 6f 64 75 63  |cher AX55,produc|
00001130  74 5f 76 65 72 3a 31 2e  30 2e 30 2c 73 70 65 63  |t_ver:1.0.0,spec|
00001140  69 61 6c 5f 69 64 3a 35  34 35 37 30 30 30 30 7d  |ial_id:54570000}|
00001150  0a 7b 70 72 6f 64 75 63  74 5f 6e 61 6d 65 3a 41  |.{product_name:A|
00001160  72 63 68 65 72 20 41 58  35 35 2c 70 72 6f 64 75  |rcher AX55,produ|
00001170  63 74 5f 76 65 72 3a 31  2e 30 2e 30 2c 73 70 65  |ct_ver:1.0.0,spe|
00001180  63 69 61 6c 5f 69 64 3a  34 41 35 30 30 30 30 30  |cial_id:4A500000|
00001190  7d 0a 7b 70 72 6f 64 75  63 74 5f 6e 61 6d 65 3a  |}.{product_name:|
000011a0  41 72 63 68 65 72 20 41  58 35 35 2c 70 72 6f 64  |Archer AX55,prod|
000011b0  75 63 74 5f 76 65 72 3a  31 2e 30 2e 30 2c 73 70  |uct_ver:1.0.0,sp|
000011c0  65 63 69 61 6c 5f 69 64  3a 35 32 35 35 30 30 30  |ecial_id:5255000|
000011d0  30 7d 0a 7b 70 72 6f 64  75 63 74 5f 6e 61 6d 65  |0}.{product_name|
000011e0  3a 41 72 63 68 65 72 20  41 58 35 35 2c 70 72 6f  |:Archer AX55,pro|
000011f0  64 75 63 74 5f 76 65 72  3a 31 2e 30 2e 30 2c 73  |duct_ver:1.0.0,s|
00001200  70 65 63 69 61 6c 5f 69  64 3a 35 33 34 37 30 30  |pecial_id:534700|
00001210  30 30 7d 73 6f 66 74 2d  76 65 72 73 69 6f 6e 00  |00}soft-version.|
00001220  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
00001230  00 00 00 00 00 02 2b 00  00 00 00 00 00 00 51 73  |......+.......Qs|
00001240  6f 66 74 5f 76 65 72 3a  31 2e 35 2e 31 31 20 42  |oft_ver:1.5.11 B|
00001250  75 69 6c 64 20 32 30 32  35 31 31 31 39 20 72 65  |uild 20251119 re|
00001260  6c 2e 34 39 35 30 33 0a  66 77 5f 69 64 3a 34 36  |l.49503.fw_id:46|
00001270  44 45 33 36 44 33 34 30  31 34 35 43 38 45 42 31  |DE36D340145C8EB1|
00001280  39 31 33 38 42 42 42 30  31 37 35 34 33 30 0a 0a  |9138BBB0175430..|
00001290  55 42 49 23 01 00 00 00  00 00 00 00 00 00 00 00  |UBI#............|
000012a0  00 00 08 00 00 00 10 00  7e a7 0d c2 00 00 00 00  |........~.......|
000012b0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
000012c0  00 00 00 00 00 00 00 00  00 00 00 00 ad 29 6e 00  |.............)n.|
000012d0  ff ff ff ff ff ff ff ff  ff ff ff ff ff ff ff ff  |................|
*
00001a90  55 42 49 21 01 01 00 05  7f ff ef ff 00 00 00 00  |UBI!............|
00001aa0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
*
00001ac0  00 00 00 00 00 00 00 00  00 00 00 00 b8 25 64 a8  |.............%d.|
00001ad0  ff ff ff ff ff ff ff ff  ff ff ff ff ff ff ff ff  |................|
*
00002290  00 00 00 32 00 00 00 01  00 00 00 00 02 00 00 06  |...2............|
000022a0  6b 65 72 6e 65 6c 00 00  00 00 00 00 00 00 00 00  |kernel..........|
000022b0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
*
00002330  00 00 00 00 00 00 00 00  0c 28 46 78 00 00 01 05  |.........(Fx....|
00002340  00 00 00 01 00 00 00 00  01 00 00 0a 75 62 69 5f  |............ubi_|
00002350  72 6f 6f 74 66 73 00 00  00 00 00 00 00 00 00 00  |rootfs..........|
00002360  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
*
000023e0  00 00 00 00 e0 b0 6e 49  00 00 00 00 00 00 00 00  |......nI........|
000023f0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
*
00002490  f1 16 c3 6b 00 00 00 00  00 00 00 00 00 00 00 00  |...k............|
000024a0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
*
--------------------------------------------------------------------

[*] Cleaning up chroot environment (will be re-extracted fresh next run)...

[*] Summary
 ├─ sha256 (orig):      ebda0049cfbfcf7f6c2a0babe36bb16fdee79ebbdb5b34f7a44c5abcd3094d85
 ├─ sha256 (decrypted): a8e90ac1f8e6364b094a65beb2c5b977953c07084c8b99d9608eb26c9160e068
 ├─ Original FW:  /home/akm/Git/Forked/tmp/Archer AX55_V1_251119/ax55v1-up-all-ver1-5-11-P1[20251119-rel49503]-2048_nosign_2025-11-19_21.03.44.bin
 └─ Decrypted FW: /home/akm/Git/Forked/tmp/Archer AX55_V1_251119/ax55v1-up-all-ver1-5-11-P1[20251119-rel49503]-2048_nosign_2025-11-19_21.03.44_decrypted.bin
```

</details>

---

## Modifying UBI Firmware (AX53, AX56, AX57, AX53HP etc)

Some TP-Link routers—including the Archer AX53, AX56, AX57, AX53HP, AX3000 etc uses a pure UBI layout with a UBIFS root filesystem. Because the layout is dynamically allocated across flash memory, standard static extraction tools often fail to correctly parse or rebuild the firmware. 

These scripts handle the extraction and repacking process automatically, dynamically capturing the exact UBI layout (LEB size, PEB counts, and journal sizes) from the target firmware. The script will use QSDK tools from bin folder. This is required because tp link uses xz compressed filesystem which standard tools installed via apt does not support. Prebuilts are already given so should work without any issue, though if it does give exec errors, rebuild the tools. (See the tools section below).

### 1. Unpacking the Firmware
To unpack a decrypted firmware image, use the `01-unpack-ubi.sh` script.

```bash
./01-unpack-ubi.sh </path/to/decrypted_firmware.bin>
```
### 2. Making Modifications

Once unpacked, you will find the entire router filesystem inside the `rootfs/` folder. You can safely add, remove, or edit scripts, configuration files, and binaries within this directory.

### 3. Repacking the Firmware

When you are done making changes, repack the firmware using the `02-repack-ubi.sh` script.

```bash
./02-repack-ubi.sh <new_custom_firmware_name.bin>
```

The repacked firmware should be there at root dir of this repo.
---

---

## Modifying SquashFS Firmware (AX55, AX72, etc)

While some TP-Link routers use a pure UBIFS layout, others—including the Archer AX55 and AX72 uses a **SquashFS over UBI** architecture. In this setup, the outer container is still UBI (for bad-block management and wear-leveling), but the inner `ubi_rootfs` volume contains a read-only, highly compressed SquashFS image rather than a dynamic UBIFS filesystem. **Important: TP-Link uses xz compressed squashfs, so we must use tools in bin folder. Standard squashfs won't be able to decode xz blocks when unpack and repack which will lead to errors. Hence we use QSDK patched mksquashfs4 and unsquashfs4.** Prebuilts are already given so should work without any issue, though if it does give exec errors, rebuild the tools. See the tools section.

### 1. Unpacking the Firmware
To unpack a decrypted SquashFS-based firmware image, use the `01-unpack-squashfs.sh` script.

```bash
./01-unpack-squashfs.sh <decrypted_firmware.bin>
```

### 2. Making Modifications

Once unpacked, you will find the entire router filesystem inside the `squashfs-root/` folder. You can safely add, remove, or edit scripts, configuration files, and binaries within this directory.

### 3. Repacking the Firmware

When you are done making changes, repack the firmware using the `02-repack-squashfs.sh` script.

```bash
./02-repack-squashfs.sh <new_custom_firmware_name.bin>
```

The repacked firmware should be there at root dir of this repo.
---

---
## Tools & Dependencies

The scripts rely on a combination of standard Linux utilities and custom, QSDK binaries built with specific patches provided in the `bin/` directory (`mkfs.ubifs`, `ubinize`, `mksquashfs4`, `unsquashfs4`, and `md5-fix`).

If needed, run `make` to compile `md5-fix`.

Because `ubi_reader` is vendored directly in the repository and the patched extraction binaries are pre-built, you no longer need to install Python modules via `pip` or the standard `squashfs-tools` package.

### Runtime Dependencies

To simply run the unpacking and repacking scripts using the included pre-built binaries, install the following standard packages:

```bash
sudo apt update
sudo apt install -y python3 fakeroot coreutils gawk
```

### Building the Tools (Ubuntu 14.04)

If the pre-built binaries in the `bin/` folder throw execution errors (often due to `glibc` version mismatches on modern Linux distributions), you must compile them from the provided vendor source.

```bash
sudo apt-get update
sudo apt-get install -y \
    build-essential \
    linux-headers-generic \
    libacl1-dev \
    liblzo2-dev \
    uuid-dev \
    zlib1g-dev \
    liblzma-dev \
    libselinux1-dev
```
### Then to build, run this from root directory.
`make tools` 

*Note: Because these are older QSDK tools, they are highly distro-specific and require legacy libraries to compile successfully. It's recommended to spin up distrobox with ubuntu 14 and use that to compile.
---

---
## Other useful information for AX53
### Firmware Downgrade Strategy

TP-Link is starting to removed most historical firmware versions from their official support pages. If you need to roll back to a previous version, you can see most old firmware in this archieve: [TP-Link Archer AX53 V1 Firmware Archive](https://archive.org/details/tp-link-archer-ax53-v1-firmware-archive). This archieve also has all GPL releases by tp link as well as my Full NAND dump - so you can use this if you happen to mess up partitions on your unit and don't happen to have a backup.

#### Standard Recovery Procedure
If your router is unresponsive or you need to force a flash, use the built-in recovery mode:
1. Power off the router.
2. Press and hold the **Reset** button.
3. Power on the router while continuing to hold Reset until the system LED turns **amber**.
4. Set your PC's Ethernet interface to a static IP: `192.168.0.10` (Subnet: `255.255.255.0`).
5. Navigate to `192.168.0.1` in your browser.
6. Upload the firmware file, confirm the flash, and wait for the process to complete. Manually reboot the router once finished.

#### Sequential Downgrade Requirement
**Warning:** Modern TP-Link firmware enforces version checks via bootloader. You **cannot** jump from a newer firmware version (e.g., 1.7.3) directly to an older one (e.g., 1.4.4).

You must downgrade **sequentially**. If you are on version 1.7.3, you must flash the next available version below it (e.g., 1.7.1), then 1.6.2, then 1.5.5, and so on, until you reach your target version.

*Example Progression:* 
`1.7.3` → `1.7.1` → `1.6.2` → `1.5.5` → `1.5.4` → `1.5.1` → `1.4.4`


### Changing region permanently
Before proceeding, note that we'll be editing tp_data partition contents, so do make sure to make a full NAND backup first!
<details>
<summary>Taking full Partition backup instructions (Click to expand)</summary>
To take full NAND backup, you need telnet or UART access with root shell. Telnet enable builds for AX53v1 can be found on this link: https://drive.google.com/drive/folders/1vr6oBHo-TKTsoGEeNcMp5J-ta0H2UMTH?usp=sharing

Download the fw and flash them from router's GUI.
 
On your local computer, start a listening node. Ensure that port `12345` is not blocked by your firewall, and note your computer's local IP address.

```bash
for mtd in $(seq 0 90); do
    echo "Waiting for mtd$mtd ..."
    nc -l -p 12345 > "mtd$mtd.bin"
    echo "Received mtd$mtd.bin, Manually interrupt if done (Ctrl + C)"
done
```

Next, telnet into the router, navigate to the `/tmp` directory, and create a script with the following contents. (Remember to replace `10.0.0.2` with your computer's actual IP address).

```bash
#!/bin/sh
LAPTOP_IP="10.0.0.2" # Replace this to your laptop ip
PORT=12345
MAX_MTD=$(($(grep -c '^mtd' /proc/mtd) - 1))

for mtd in $(seq 0 $MAX_MTD); do
    echo "Sending mtd$mtd ..."
    dd if=/dev/mtd$mtd bs=1M 2>/dev/null | nc $LAPTOP_IP $PORT
    echo "Sent mtd$mtd"
    sleep 2
done
echo "All partitions sent."
```

Make the script executable and run it. The workflow should look similar to this:

```bash
akm@RHEL:~/Git/Forked/tmp/mimo/fw/latest/out$ telnet 192.168.0.1
Trying 192.168.0.1...
Connected to 192.168.0.1.
Escape character is '^]'.

 === IMPORTANT ============================
  Use 'passwd' to set your login password
  this will disable telnet and enable SSH
 ------------------------------------------


BusyBox v1.19.4 (2025-03-14 21:48:08 CST) built-in shell (ash)
Enter 'help' for a list of built-in commands.

     MM           NM                    MMMMMMM          M       M
   $MMMMM        MMMMM                MMMMMMMMMMM      MMM     MMM
  MMMMMMMM     MM MMMMM.              MMMMM:MMMMMM:   MMMM   MMMMM
MMMM= MMMMMM  MMM   MMMM       MMMMM   MMMM  MMMMMM   MMMM  MMMMM'
MMMM=  MMMMM MMMM    MM       MMMMM    MMMM    MMMM   MMMMNMMMMM
MMMM=   MMMM  MMMMM          MMMMM     MMMM    MMMM   MMMMMMMM
MMMM=   MMMM   MMMMMM       MMMMM      MMMM    MMMM   MMMMMMMMM
MMMM=   MMMM     MMMMM,    NMMMMMMMM   MMMM    MMMM   MMMMMMMMMMM
MMMM=   MMMM      MMMMMM   MMMMMMMM    MMMM    MMMM   MMMM  MMMMMM
MMMM=   MMMM   MM    MMMM    MMMM      MMMM    MMMM   MMMM    MMMM
MMMM$ ,MMMMM  MMMMM  MMMM    MMM       MMMM   MMMMM   MMMM    MMMM
  MMMMMMM:      MMMMMMM     M         MMMMMMMMMMMM  MMMMMMM MMMMMMM
    MMMMMM       MMMMN     M           MMMMMMMMM      MMMM    MMMM
     MMMM          M                    MMMMMMM        M       M
       M
 ---------------------------------------------------------------
   For those about to rock... (Attitude Adjustment, unknown)
 ---------------------------------------------------------------
root@Archer_AX53:/# cd /tmp
root@Archer_AX53:/tmp# mkdir -p backup
root@Archer_AX53:/tmp# cd backup
root@Archer_AX53:/tmp/backup# ls
bak.sh
root@Archer_AX53:/tmp/backup# cat bak.sh
#!/bin/sh
LAPTOP_IP="192.168.0.80"
PORT=12345
MAX_MTD=$(($(grep -c '^mtd' /proc/mtd) - 1))

for mtd in $(seq 0 $MAX_MTD); do
    echo "Sending mtd$mtd ..."
    dd if=/dev/mtd$mtd bs=1M 2>/dev/null | nc $LAPTOP_IP $PORT
    echo "Sent mtd$mtd"
    sleep 2
done
echo "All partitions sent."
                
root@Archer_AX53:/tmp/backup# chmod +x bak.sh
root@Archer_AX53:/tmp/backup# ./bak.sh
Sending mtd0 ...
Sent mtd0
Sending mtd1 ...
Sent mtd1
Sending mtd2 ...
Sent mtd2
Sending mtd3 ...
Sent mtd3
Sending mtd4 ...
Sent mtd4
Sending mtd5 ...
Sent mtd5
Sending mtd6 ...
Sent mtd6
Sending mtd7 ...
Sent mtd7
Sending mtd8 ...
Sent mtd8
Sending mtd9 ...
Sent mtd9
Sending mtd10 ...
Sent mtd10
Sending mtd11 ...
Sent mtd11
Sending mtd12 ...
Sent mtd12
Sending mtd13 ...
Sent mtd13
Sending mtd14 ...
Sent mtd14
Sending mtd15 ...
Sent mtd15
Sending mtd16 ...
Sent mtd16
Sending mtd17 ...
Sent mtd17
Sending mtd18 ...
Sent mtd18
Sending mtd19 ...
Sent mtd19
All partitions sent.
root@Archer_AX53:/tmp/backup# exit
Connection closed by foreign host.
```

On your laptop you should've received all partitions:
```bash
akm@RHEL:~/Git/Clonned/Official/router-fw/rax120v2/Stock-Backup/tmp$ for mtd in $(seq 0 90); do
    echo "Waiting for mtd$mtd ..."
    nc -l -p 12345 > "mtd$mtd.bin"
    echo "Received mtd$mtd.bin, Manually interrupt if done (Ctrl + C)"
done
Waiting for mtd0 ...
Received mtd0.bin, Manually interrupt if done (Ctrl + C)
Waiting for mtd1 ...
Received mtd1.bin, Manually interrupt if done (Ctrl + C)
Waiting for mtd2 ...
Received mtd2.bin, Manually interrupt if done (Ctrl + C)
Waiting for mtd3 ...
Received mtd3.bin, Manually interrupt if done (Ctrl + C)
Waiting for mtd4 ...
Received mtd4.bin, Manually interrupt if done (Ctrl + C)
Waiting for mtd5 ...
Received mtd5.bin, Manually interrupt if done (Ctrl + C)
Waiting for mtd6 ...
Received mtd6.bin, Manually interrupt if done (Ctrl + C)
Waiting for mtd7 ...
Received mtd7.bin, Manually interrupt if done (Ctrl + C)
Waiting for mtd8 ...
Received mtd8.bin, Manually interrupt if done (Ctrl + C)
Waiting for mtd9 ...
Received mtd9.bin, Manually interrupt if done (Ctrl + C)
Waiting for mtd10 ...
Received mtd10.bin, Manually interrupt if done (Ctrl + C)
Waiting for mtd11 ...
Received mtd11.bin, Manually interrupt if done (Ctrl + C)
Waiting for mtd12 ...
Received mtd12.bin, Manually interrupt if done (Ctrl + C)
Waiting for mtd13 ...
Received mtd13.bin, Manually interrupt if done (Ctrl + C)
Waiting for mtd14 ...
Received mtd14.bin, Manually interrupt if done (Ctrl + C)
Waiting for mtd15 ...
Received mtd15.bin, Manually interrupt if done (Ctrl + C)
Waiting for mtd16 ...
Received mtd16.bin, Manually interrupt if done (Ctrl + C)
Waiting for mtd17 ...
Received mtd17.bin, Manually interrupt if done (Ctrl + C)
Waiting for mtd18 ...
Received mtd18.bin, Manually interrupt if done (Ctrl + C)
Waiting for mtd19 ...
Received mtd19.bin, Manually interrupt if done (Ctrl + C)
Waiting for mtd20 ...
^C
akm@RHEL:~/Git/Clonned/Official/router-fw/rax120v2/Stock-Backup/tmp$ ls
mtd0.bin   mtd12.bin  mtd15.bin  mtd18.bin  mtd20.bin  mtd4.bin  mtd7.bin
mtd10.bin  mtd13.bin  mtd16.bin  mtd19.bin  mtd2.bin   mtd5.bin  mtd8.bin
mtd11.bin  mtd14.bin  mtd17.bin  mtd1.bin   mtd3.bin   mtd6.bin  mtd9.bin
```
</details>
You need Telnet or UART access with a root shell to perform a full backup. Telnet-enabled firmware builds for the AX53v1 can be found here: 

[Telnet Enabled Builds](https://drive.google.com/drive/folders/1vr6oBHo-TKTsoGEeNcMp5J-ta0H2UMTH?usp=sharing)

Download the appropriate firmware and flash it from the router's GUI.

Once you have a backup and installed telnet-enabled fw, telnet onto the router and go to `/tp_data` dir. You need to edit `product-info` file and change `special_id` and `country` fields to your desired value. Special ID and Country codes can be found inside `/sbin/wifi_check_country` file. Below is a snippet for all available special ID and country codes:

<details>
<summary>Country Codes section from wifi_check_country (Click to expand)</summary>

```text
WIFIDEVICES=
SIDLIST="UN US EU CA KR BR JP AU RU TW SG AS EG"

#define special id for country code
UN_sid=00000000
US_sid=55530000
EU_sid=45550000
CA_sid=43410000
KR_sid=4B520000
BR_sid=42520000
JP_sid=4A500000
AU_sid=41550000
RU_sid=52550000
TW_sid=54570000
SG_sid=53470000
AS_sid=41530000
EG_sid=45470000

#define country for country code
US_country="US"
EU_country="GB BZ DE"
CA_country="CA"
KR_country="KR UN"
BR_country="BR"
JP_country="JP"
AU_country="AU NZ"
RU_country="RU"
TW_country="TW"
SG_country="SG"
AS_country="AS"
EG_country="EG"

#define default for each country code
US_default_country="US"
EU_default_country="DE"
CA_default_country="CA"
KR_default_country="KR"
BR_default_country="BR"
JP_default_country="JP"
AU_default_country="AU"
RU_default_country="RU"
TW_default_country="TW"
SG_default_country="SG"
AS_default_country="AS"
EG_default_country="EG"
```
</details>

The using vi or by any other means, edit `product-info` file and change `special_id` and `country` field according to which ever you want. save and reboot -- this change will be permanent as /tp_data is direct mount of mtd13 and this is a separate persistent UBI volume. This change will survive reboots and standard firmware upgrades.

Here is an example of what the file should look like after changing the region to `US`.

```text
akm@RHEL:~/Git/Forked/tmp/mimo/fw/latest/out$ telnet 192.168.0.1
Trying 192.168.0.1...
Connected to 192.168.0.1.
Escape character is '^]'.

 === IMPORTANT ============================
  Use 'passwd' to set your login password
  this will disable telnet and enable SSH
 ------------------------------------------


BusyBox v1.19.4 (2025-03-14 21:48:08 CST) built-in shell (ash)
Enter 'help' for a list of built-in commands.

     MM           NM                    MMMMMMM          M       M
   $MMMMM        MMMMM                MMMMMMMMMMM      MMM     MMM
  MMMMMMMM     MM MMMMM.              MMMMM:MMMMMM:   MMMM   MMMMM
MMMM= MMMMMM  MMM   MMMM       MMMMM   MMMM  MMMMMM   MMMM  MMMMM'
MMMM=  MMMMM MMMM    MM       MMMMM    MMMM    MMMM   MMMMNMMMMM
MMMM=   MMMM  MMMMM          MMMMM     MMMM    MMMM   MMMMMMMM
MMMM=   MMMM   MMMMMM       MMMMM      MMMM    MMMM   MMMMMMMMM
MMMM=   MMMM     MMMMM,    NMMMMMMMM   MMMM    MMMM   MMMMMMMMMMM
MMMM=   MMMM      MMMMMM   MMMMMMMM    MMMM    MMMM   MMMM  MMMMMM
MMMM=   MMMM   MM    MMMM    MMMM      MMMM    MMMM   MMMM    MMMM
MMMM$ ,MMMMM  MMMMM  MMMM    MMM       MMMM   MMMMM   MMMM    MMMM
  MMMMMMM:      MMMMMMM     M         MMMMMMMMMMMM  MMMMMMM MMMMMMM
    MMMMMM       MMMMN     M           MMMMMMMMM      MMMM    MMMM
     MMMM          M                    MMMMMMM        M       M
       M
 ---------------------------------------------------------------
   For those about to rock... (Attitude Adjustment, unknown)
 ---------------------------------------------------------------
root@Archer_AX53:/# cd /tp_data
root@Archer_AX53:/tp_data# ls
art_backup.tgz  default-mac     device-id       https_cert      pin             product-info    tss_data        user-config
root@Archer_AX53:/tp_data# cat product-info
vendor_name:TP-Link
vendor_url:www.tp-link.com
product_name:Archer AX53
device_name:Wireless Router Archer AX53
country:US
product_ver:1.0.0
hw_ver:00000001
product_id:30003001
special_id:55530000
hw_id:B8A21A250D06358193A839AAFE53DB78
oem_id:33407C629E68ACD6503BFE6D4A596762
```

After reboot you may also check your current `special_id` and `country` using the `getfirm` function

```text
root@Archer_AX53:/# getfirm
getfirm <info>
        MAC
        SSID
        PIN
        MODEL
        FIRM
        WEBSITE
        HARDVERSION
        SOFTVERSION
        LANGUAGE
        PRODUCT_ID
        SPECIAL_ID
        DEV_ID
        HW_ID
        FW_ID
        OEM_ID
        COUNTRY
        HW_VER
        DEVICE_NAME
        HOSTNAME_NO_BLANK
        PASSWORD
        PRECONF_GID
        PRECONF_KEY
        PRECONF_PACK
root@Archer_AX53:/# getfirm SPECIAL_ID
55530000
root@Archer_AX53:/# getfirm COUNTRY
US
```

---
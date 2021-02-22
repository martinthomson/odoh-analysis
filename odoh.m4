changequote(<!,!>)
changecom(<!/*!>,<!*/!>)

include(msgs.m4i)
include(crypto.m4i)

theory ODoH begin

builtins: diffie-hellman, hashing, symmetric-encryption, signing

functions: Expand/3, Extract/2, hmac/1, aead/3, decrypt/2, aead_verify/3

restriction Eq_check_succeed: "All x y #i. Eq(x,y) @ i ==> x = y"
restriction Neq_check_succeed: "All x y #i. Neq(x,y) @ i ==> not (x = y)"


/* The plaintext can be recovered with the key */
equations: decrypt(aead(k, p, a), k) = p
/* The authentication can be checked with the key and AAD */
equations: aead_verify(aead(k, p, a), a, k) = true

/* The Starter rule establishes an authentic shared key between two actors, and produces the KeyExI Fact, which the attacker can use to compromise said key. */
rule Starter:
  [ Fr(~kxy) ]
--[ Channel($X, $Y) ]->
  [ KeyExC($X, $Y, ~kxy)
  , KeyExS($X, $Y, ~kxy)
  , KeyExI($X, $Y, ~kxy)
  ]

/* The Generate_DH_key_pair rule simulates the PKI necessary for distributing the target's keys. In the case of ODoH this is done in DNS itself. */
rule Generate_DH_key_pair:
  [ Fr(~x)
  , Fr(~key_id)
  ]
-->
  [ !Pk($A, ~key_id, 'g'^~x)
  , Out(<~key_id, 'g'^~x>)
  , !Ltk($A,~key_id, ~x)
  ]

/* The C_QueryGeneration rule simulates the client establishing a connection to the proxy and sending a query.
It consumes a key from the starter, allowing it to communicate with proxy securely. */
rule C_QueryGeneration:
let
  gx = 'g'^~x
  kem_context = <gx, gy>
  dh = gy^~x
/* The ExtractAndExpand rules are provided in crypto.m4i. */
  shared_secret = ExtractAndExpand(dh, kem_context)
  response_secret = ExtractAndExpand(shared_secret, 'odoh_response')
  key_id = ~key_id
  msg_type='0x01'
  query = ~q
  msg_id = ~msg_id
in
  [ KeyExC($C, $P, ~k)
  , !Pk($T, ~key_id, gy)
  , Fr(~x)
  , Fr(~msg_id)
  /* The connection_id is used to uniquely identify a connection between the client and the proxy. 
   By sending it encrypted only with the connection key we are able to easily determine whether the attacker can decrypt the connection between the client and the proxy by checking if it can discover this value. */
  , Fr(~connection_id)
  , Fr(~q)
  ]
--[ /* We require the proxy and the target to be distinct. */
    Neq($P, $T) 
  /* This action tells Tamarin the ultimate source of message ids, client key shares, and encrypted queries. */
  , CQE_sources( ~msg_id, gx, ODoHEBody )
  /* This action uniquely specifies a client making a query. */
  , CQE($C, $P, $T, ~connection_id, ~q, ~msg_id, gx, gy, ~k)
  ]->
  [ Out(senc(<~connection_id, $T, ODoHQuery>, ~k))
  /* This Fact stores the client's state. */
  , C_ResponseHandler(query, $C, gx,  $P, ~k,  $T, gy, response_secret, ~msg_id)
  ]

/* The P_HandleQuery rule simulates a proxy receiving a query, and forwarding it to the target.
It consumes the key from the starter rule, binding the client and proxy together. */
rule P_HandleQuery:
let
  expected_msg_type = '0x01'
in
  [ KeyExS($C, $P, ~k)
  , In(senc(<~connection_id, $T, <ODoHHeader, <gx, opaque_message>>>, ~k))
  , Fr(~ptid)
  /* The proxy takes the key id from the attacker. 
   Although this makes the attacker strictly more powerful, and thus doesn't compromise our results, the goal is not a security property.
   It simply makes the model more efficient. */
  , In(key_id)
  ]
--[ /* This action uniquely specifies the proxy receiving and forwarding the query. */
    PHQ(msg_id, gx, opaque_message) 
  /* The proxy will only accept messages with type '0x01', i.e. queries.
   It rejects responses on this interface. */
  , Eq(msg_type, expected_msg_type)
  ]->
  [Out(<$T, <ODoHHeader, <gx, opaque_message>>>)
  /* This Fact stores the proxy's state. */
  , P_ResponseHandler(~ptid, $C, $P, ~k, msg_id)
  ]

rule T_HandleQuery:
let
  expected_msg_type = '0x01'
  gy = 'g'^~y
  kem_context = <gx, gy>
  dh = gx^~y
  shared_secret = ExtractAndExpand(dh, kem_context)
  response_secret = ExtractAndExpand(shared_secret, 'odoh_response')
  expected_aad = <L, key_id, '0x01'>
  key_id = ~key_id
  msg_type2 = '0x02'
  psk = response_secret
  answer = r
in
  [ In(<$T, ODoHQuery>)
  , !Ltk($T, ~key_id, ~y)
  , Fr(~ttid)
  /* The attacker is allowed to choose the response.
   We allow this because it means we do not need to consider the security of the connection between the recursive resolver and the authorative resolver. */
  , In(r)
  ]
--[ /* The target only accepts queries. */
    Eq(msg_type, expected_msg_type) 
  /* This action requires the message to correctly decrypt.
   In practice this is already in forced by the pattern matching of the input rule, but we leave this action as a signal of the requirement. */
  , Eq(aead_verify(ODoHEBody, <L, key_id, '0x01'>, shared_secret), true)
  /* This action uniquely specifies the target completing the protcol. */
  , T_Done(~ttid, msg_id)
  , T_Answer($T, query, answer)
  ]->
  [ Out(ODoHResponse2) ]

rule P_HandleResponse:
let
  expected_msg_type = '0x02'
in
  [ /* The proxy consumes its previous state. */
    P_ResponseHandler(~ptid, $C, $P, ~k, msg_id) 
  , In(<ODoHHeader, opaque_message>)
  ]
--[ /* This actions uniquely specifies the proxy completing the protocol. */
    P_Done(~ptid, msg_id) 
  /* The proxy will only accept responses on this interface. */
  , Eq(msg_type, expected_msg_type)
  ]->
  [ Out(senc(<ODoHHeader, opaque_message>, ~k)) ]

rule C_HandleResponse:
let
  expected_msg_type = '0x02'
  psk = response_secret
  msg_id = ~msg_id
in
  [ /* The client consumes its previous state. */
    C_ResponseHandler(~query, $C, gx, $P, ~k,  $T, gy, response_secret, ~msg_id) 
  , In(senc(ODoHResponse, ~k)) ]
--[ /* The client only accepts responses on this interface. */
    Eq(msg_type, expected_msg_type) 
  /* This action requires the response to correctly decrypt.
   As with the target this is already enforced by the pattern matching done on the input, but we leave it here as a signal of the requirement. */
  , Eq(aead_verify(aead(psk, answer, <L, key_id, '0x02'>), <L, key_id, '0x02'>, psk), true)
  /* This action uniquely specifies the client completing the protcol. */
  , C_Done(~query, answer, $C, gx,  $T, gy)
  ]->
  /* Because this analysis only considers the ODoH protocol, and not reaction attacks, at this point we can drop all the client state. */
  []

/* This rule allows the attacker perform the RevSk action to reveal a connection handshake key. */
rule RevSK:
  [ KeyExI($X, $Y, ~kxy) ]
--[ RevSk(~kxy) ]->
  [ Out(~kxy) ]

/* This rule allows the attacker to perform the RevDH action to reveal a target's key share. */
rule RevDH:
  [ !Ltk($A,~key_id, ~x) ]
--[ RevDH($A, ~key_id, 'g'^~x) ]->
  [ Out(~x) ]

/* This lemma is used by Tamarin's preprocessor to refine the outputs of the P_HandleQuery rule. 
 It can understood as "Either the inputs to the P_HandleQuery rule are from an honest client, or the attacker knew them before the rule was triggered." */
lemma PHQ_source[sources]:
  "All mid gx op #j. PHQ(mid, gx, op)@j ==> (Ex #i. CQE_sources(mid, gx, op)@i & #i < #j) | ((Ex #i. KU(mid)@i & #i < #j) & (Ex #i. KU(gx)@i & #i < #j) & (Ex #i. KU(op)@i & #i < #j))"

/* This lemma is an existance lemma, and checks that it is possible for the protocol to complete.
 This reduces the risk that the model is satisfied trivially, because some bug renders it unable to run. */
lemma end_to_end:
  exists-trace
  "Ex q a  C gx T gy #i. C_Done(q, a, C, gx, T, gy)@i"

/* This lemma states that if the attacker learns the query then it must have previously compromised the target. */
lemma secret_query:
  "All C P T cid q msg_id gx gy key #j #k.
    CQE(C, P, T, cid, q, msg_id, gx, gy, key)@j &
    KU(q)@k
==>
  Ex kid #i.
    RevDH(T, kid, gy)@i &
    #i < #k"

/* This lemma states that if the attacker learns the connection id then it must have previously compromised the proxy. */
lemma secret_cid:
  "All C P T cid q msg_id gx gy key #j #k.
    CQE(C, P, T, cid, q, msg_id, gx, gy, key)@j &
    KU(cid)@k
==>
  Ex #i.
    RevSk(key)@i &
    #i < #k"
  
/* This lemma states that if the attacker learns both the connection id and the query then it must have previously compromised the target and the proxy. */
lemma query_binding:
  "All C P T cid q msg_id gx gy key #j #k #l.
    CQE(C, P, T, cid, q, msg_id, gx, gy, key)@j &
    KU(q)@k &
    KU(cid)@l
==>
  Ex kid #h #i.
    RevDH(T, kid, gy)@i &
    #i < #k &
    RevSk(key)@h &
    #h < #l"

/* This lemma states that if the client and target both complete the protocol then either they agree on the target's identity, the query, and the answer or the attacker previously compromised the target. */
lemma consistency:
  "All q a C gx T gy #j. C_Done(q, a, C, gx, T, gy)@j
==>
  (Ex #i. T_Answer(T, q, a)@i & #i < #j) |
  (Ex kid #i.
    RevDH(T, kid, gy)@i &
    #i < #j)"


end

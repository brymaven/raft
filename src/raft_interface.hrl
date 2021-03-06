%% Message interface between raft nodes
-record(entry, {term, command}).
-record(state, {term=0, voted_for=array:new({fixed, false}), log, node_id,
                addresses, timeout, timer_ref, leader_id, commit_index=0, last_applied=0,
                votes=0, indexes, machine=machine:new()}).
-record(append_entry, {prev_term,
                       prev_index,
                       cur_term,
                       cur_index,
                       command,
                       entries,
                       leader_id,
                       leader_commit}).
-record(append_response, {node_id, term, success}).
-record(request_vote, {term, candidate_id, last_log_index, last_log_term}).
-record(vote_response, {term, vote_granted}).
-record(client_call, {from, command}).

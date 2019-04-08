#lang syndicate

(require (only-in racket/set
                  set
                  set-count
                  set-empty?
                  set-first
                  set-remove
                  set-add))
(require (only-in racket/list
                  partition
                  empty?
                  split-at))
(require (only-in racket/hash
                  hash-union))
(require (only-in racket/string
                  string-split
                  string-trim))
(require (only-in racket/sequence
                  sequence->list))

(module+ test
  (require rackunit))

;; ---------------------------------------------------------------------------------------------------
;; Protocol

#|
Conversations in the flink dataspace primarily concern two topics: presence and
task execution.

Presence Protocol
-----------------

The JobManager (JM) asserts its presence with (job-manager-alive). The operation
of each TaskManager (TM) is contingent on the presence of a job manager.
|#
(assertion-struct job-manager-alive ())
#|
In turn, TaskManagers advertise their presence with (task-manager ID slots),
where ID is a unique id, and slots is a natural number. The number of slots
dictates how many tasks the TM can take on. To reduce contention, the JM
should only assign a task to a TM if the TM actually has the resources to
perform a task.
|#
(assertion-struct task-manager (id slots))
;; an ID is a symbol or a natural number.
;; Any -> Bool
;; recognize IDs
(define (id? x)
  (or (symbol? x) (exact-nonnegative-integer? x)))
#|
The resources available to a TM are its associated TaskRunners (TRs). TaskRunners
assert their presence with (task-runner ID Status), where Status is one of
  - IDLE, when the TR is not executing a task
  - (executing ID), when the TR is executing the task with the given ID
  - OVERLOAD, when the TR has been asked to perform a task before it has
    finished its previous assignment. For the purposes of this model, it indicates a
    failure in the protocol; like the exchange between the JM and the TM, a TR
    should only receive tasks when it is IDLE.
|#
(assertion-struct task-runner (id status))
(define IDLE 'idle)
(define OVERLOAD 'overload)
(struct executing (id) #:transparent)

#|
Task Delegation Protocol
-----------------------

Task Delegation has two roles, TaskAssigner (TA) and TaskPerformer (TP).

A TaskAssigner asserts the association of a Task with a particular TaskPerformer
through
    (task-assignment ID ID Task)
where the first ID identifies the TP and the second identifies the job.
|#
(assertion-struct task-assignment (assignee job-id task))
#|
A Task is a (task ID Work), where Work is one of
  - (map-work String)
  - (reduce-work (U ID TaskResult) (U ID TaskResult)), referring to either the
    ID of the dependent task or its results. A reduce-work is ready to be executed
    when it has both results.

A TaskResult is a (Hashof String Natural), counting the occurrences of words
|#
(struct task (id desc) #:transparent)
(struct map-work (data) #:transparent)
(struct reduce-work (left right) #:transparent)

#|
The TaskPerformer responds to a task-assignment by describing its state with respect
to that task,
    (task-state ID ID ID TaskStateDesc)
where the first ID is that of the TP, the second is that of the job,
and the third that of the task.

A TaskStateDesc is one of
  - ACCEPTED, when the TP has the resources to perform the task. (TODO - not sure if this is ever visible, currently)
  - OVERLOAD, when the TP does not have the resources to perform the task.
  - RUNNING, indicating that the task is being performed
  - (finished TaskResult), describing the results
|#
(assertion-struct task-state (assignee job-id task-id desc))
(struct finished (data) #:transparent)
(define ACCEPTED 'accepted)
(define RUNNING 'running)
#|
Two instances of the Task Delegation Protocol take place: one between the
JobManager and the TaskManager, and one between the TaskManager and its
TaskRunners.
|#

#|
Job Submission Protocol
-----------------------

Finally, Clients submit their jobs to the JobManager by asserting a Job, which is a (job ID (Listof Task)).
The JobManager then performs the job and, when finished, asserts (job-finished ID TaskResult)
|#
(assertion-struct job (id tasks))
(assertion-struct job-finished (id data))

;; ---------------------------------------------------------------------------------------------------
;; Logging

(define (log fmt . args)
  (displayln (apply format fmt args)))

;; ---------------------------------------------------------------------------------------------------
;; Generic Implementation of Task Delegation Protocol

;; a TaskFun is a
;; (Task ID (TaskResults -> Void) ((U ACCEPTED OVERLOAD RUNNING) -> Void) -> Void)

;; ID (-> Bool) TaskFun -> TaskPerformer
;; doesn't really account for long-running tasks
;; gonna need some effect polymorphism to type uses of this
(define (task-performer my-id can-accept? perform-task)
  (react
   (during (task-assignment my-id $job-id $task)
     (field [status #f])
     (assert (task-state my-id job-id (task-id task) (status)))
     (cond
       [(can-accept?)
        (status RUNNING)
        (define (on-complete results)
          (status (finished results)))
        (perform-task task job-id on-complete status)]
       [else
        (status OVERLOAD)]))))

;; Task
;; ID
;; ID
;; (-> Void)
;; (TaskResults -> Void)
;; -> TaskAssigner
(define (task-assigner tsk job-id performer
                       on-overload!
                       on-complete!)
  (react
   (assert (task-assignment performer job-id tsk))
   (on (asserted (task-state performer job-id (task-id tsk) $status))
       (match status
         [(or (== ACCEPTED)
              (== RUNNING))
          (void)]
         [(== OVERLOAD)
          (stop-current-facet (on-overload!))]
         [(finished results)
          (stop-current-facet (on-complete! results))]))))

;; ---------------------------------------------------------------------------------------------------
;; TaskRunner

(define (spawn-task-runner)
  (define id (gensym 'task-runner))
  (spawn #:name id
   (field [status IDLE])
   (define (idle?) (equal? IDLE (status)))
   (assert (task-runner id (status)))
   (begin/dataflow
     (log "task-runner ~v state is: ~a" id (status)))
   ;; Task (TaskStateDesc -> Void) -> Void
   (define (perform-task tsk job-id on-complete! update-status!)
     (unless (idle?)
       (error "tried to perform a task when not idle"))
     ;; since we currently finish everything in one turn, these changes to status aren't
     ;; actually visible.
     (status RUNNING)
     (match-define (task tid desc) tsk)
     (match desc
       [(map-work data)
        (define wc (count-new-words (hash) (string->words data)))
        (on-complete! wc)]
       [(reduce-work left right)
        (define wc (hash-union left right #:combine +))
        (on-complete! wc)])
     (status IDLE))
   (on-start
    (task-performer id idle? perform-task))))

;; (Hash String Nat) String -> (Hash String Nat)
(define (word-count-increment h word)
  (hash-update h
               word
               add1
               (λ x 0)))

;; (Hash String Nat) (Listof String) -> (Hash String Nat)
(define (count-new-words word-count words)
  (for/fold ([result word-count])
            ([word words])
    (word-count-increment result word)))

;; String -> (Listof String)
;; Return the white space-separated words, trimming off leading & trailing punctuation
(define (string->words s)
  (map (lambda (w) (string-trim w #px"\\p{P}")) (string-split s)))

(module+ test
  (check-equal? (string->words "good day sir")
                (list "good" "day" "sir"))
  (check-equal? (string->words "")
                (list))
  (check-equal? (string->words "good eve ma'am")
                (list "good" "eve" "ma'am"))
  (check-equal? (string->words "please sir. may I have another?")
                (list "please" "sir" "may" "I" "have" "another"))
  ;; TODO - currently fails
  #;(check-equal? (string->words "but wait---there's more")
                (list "but" "wait" "there's" "more")))

;; ---------------------------------------------------------------------------------------------------
;; TaskManager

(define (spawn-task-manager)
  (define id (gensym 'task-manager))
  (spawn #:name id
   (log "Task Manager (TM) ~a is running" id)
   (during (job-manager-alive)
     (log "TM learns about JM")
     (define/query-set task-runners (task-runner $id _) id
       #:on-add (log "TM learns about task-runner ~a" id))
     ;; I wonder just how inefficient this is
     (define/query-set idle-runners (task-runner $id IDLE) id
       #:on-add (log "TM learns that task-runner ~a is IDLE" id)
       #:on-remove (log "TM learns that task-runner ~a is NOT IDLE" id))
     (assert (task-manager id (set-count (idle-runners))))
     (field [busy-runners (list)])
     (define (can-accept?)
       (not (set-empty? (idle-runners))))
     (define (perform-task tsk job-id on-complete! update-status!)
       (match-define (task task-id desc) tsk)
       (define runner (set-first (idle-runners)))
       ;; n.b. modifying a query set is questionable
       ;; but if we wait for the IDLE assertion to be retracted, we might assign multiple tasks to the same runner.
       ;; Could use the busy-runners field to avoid that
       (idle-runners (set-remove (idle-runners) runner))
       (log "TM assigns task ~a to runner ~a" task-id runner)
       ;; TODO - since we're both adding and removing from this set I'm not sure TRs
       ;; need to be making assertions about their idleness
       (on-stop (idle-runners (set-add (idle-runners) runner)))
       (on-start
        (task-assigner tsk job-id runner
                      (lambda () (update-status! OVERLOAD))
                      (lambda (results) (on-complete! results)))))
     (on-start
      (task-performer id can-accept? perform-task)))))

;; ---------------------------------------------------------------------------------------------------
;; JobManager

(define (spawn-job-manager)
  (spawn
    (assert (job-manager-alive))
    (log "Job Manager Up")

    ;; keep track of task managers, how many slots they say are open, and how many tasks we have assigned.
    (define/query-hash task-managers (task-manager $id $slots) id slots
      #:on-add (log "JM learns that ~a has ~v slots" id slots))

    ;; (Hashof TaskManagerID Nat)
    ;; to better understand the supply of slots for each task manager, keep track of the number
    ;; of requested tasks that we have yet to hear back about
    (field [requests-in-flight (hash)])
    (define (slots-available)
      (for/sum ([(id v) (in-hash (task-managers))])
        (max 0 (- v (hash-ref (requests-in-flight) id 0)))))
    ;; ID -> Void
    ;; mark that we have requested the given task manager to perform a task
    (define (take-slot! id)
      (log "JM assigns a task to ~a" id)
      (requests-in-flight (hash-update (requests-in-flight) id add1 0)))
    ;; ID -> Void
    ;; mark that we have heard back from the given manager about a requested task
    (define (received-answer! id)
      (requests-in-flight (hash-update (requests-in-flight) id sub1)))

    (during (job $job-id $tasks)
      (log "JM receives job ~a" job-id)
      (define-values (ready not-ready) (partition task-ready? tasks))
      (field [ready-tasks ready]
             [waiting-tasks not-ready]
             [tasks-in-progress 0])

      (begin/dataflow
        (define slots (slots-available))
        (define-values (ts readys)
          (split-at/lenient (ready-tasks) slots))
        (for ([t ts])
          (perform-task t push-results))
        (unless (empty? ts)
          ;; the empty? check may be necessary to avoid a dataflow loop
          (ready-tasks readys)))

      ;; Task -> Void
      (define (add-ready-task! t)
        ;; TODO - use functional-queue.rkt from ../../
        (log "JM marks task ~a as ready" (task-id t))
        (ready-tasks (cons t (ready-tasks))))

      ;; Task (ID TaskResult -> Void) -> Void
      ;; Requires (task-ready? t)
      (define (perform-task t k)
        (react
         (define task-facet (current-facet-id))
         (on-start (tasks-in-progress (add1 (tasks-in-progress))))
         (on-stop (tasks-in-progress (sub1 (tasks-in-progress))))
         (match-define (task this-id desc) t)
         (log "JM begins on task ~a" this-id)

         (define (select-a-task-manager)
           (react
            (begin/dataflow
              (define mngr
                (for/first ([(id slots) (in-hash (task-managers))]
                            #:when (positive? (- slots (hash-ref (requests-in-flight) id 0))))
                  id))
              (when mngr
                (take-slot! mngr)
                (stop-current-facet (assign-task mngr))))))

         ;; ID -> ...
         (define (assign-task mngr)
           (react
            (define this-facet (current-facet-id))
            (on (retracted (task-manager mngr _))
                ;; our task manager has crashed
                (stop-current-facet (select-a-task-manager)))
            (on-start
             ;; N.B. when this line was here, and not after `(when mngr ...)` above,
             ;; things didn't work. I think that due to script scheduling, all ready
             ;; tasks were being assigned to the manager
             #;(take-slot! mngr)
             (react (stop-when (asserted (task-state mngr job-id this-id _))
                               (received-answer! mngr)))
             (task-assigner t job-id mngr
                            (lambda ()
                              ;; need to find a new task manager
                              ;; don't think we need a release-slot! here, because if we've heard back from a task manager,
                              ;; they should have told us a different slot count since we tried to give them work
                              (log "JM overloaded manager ~a with task ~a" mngr this-id)
                              (stop-facet this-facet (select-a-task-manager)))
                            (lambda (results)
                              (log "JM receives the results of task ~a" this-id)
                              (stop-facet task-facet (k this-id results)))))))

         (on-start (select-a-task-manager))))

      ;; ID Data -> Void
      ;; Update any dependent tasks with the results of the given task, moving
      ;; them to the ready queue when possible
      (define (push-results task-id data)
        (cond
          [(and (zero? (tasks-in-progress))
                (empty? (ready-tasks))
                (empty? (waiting-tasks)))
           (log "JM finished with job ~a" job-id)
           (react (assert (job-finished job-id data)))]
          [else
           ;; TODO - in MapReduce, there should be either 1 waiting task, or 0, meaning the job is done.
           (define still-waiting
             (for/fold ([ts '()])
                       ([t (in-list (waiting-tasks))])
               (define t+ (task+data t task-id data))
               (cond
                 [(task-ready? t+)
                  (add-ready-task! t+)
                  ts]
                 [else
                  (cons t+ ts)])))
           (waiting-tasks still-waiting)]))
      #f)))

;; Task -> Bool
;; Test if the task is ready to run
(define (task-ready? t)
  (match t
    [(task _ (reduce-work l r))
     (not (or (id? l) (id? r)))]
    [_ #t]))

;; Task Id Any -> Task
;; If the given task is waiting for this data, replace the waiting ID with the data
(define (task+data t id data)
  (match t
    [(task tid (reduce-work (== id) r))
     (task tid (reduce-work data r))]
    [(task tid (reduce-work l (== id)))
     (task tid (reduce-work l data))]
    [_ t]))


;; (Listof A) Nat -> (Values (Listof A) (Listof A))
;; like split-at but allow a number larger than the length of the list
(define (split-at/lenient lst n)
  (split-at lst (min n (length lst))))

;; ---------------------------------------------------------------------------------------------------
;; Client

;; Job -> Void
(define (spawn-client j)
  (spawn
   (assert j)
   (on (asserted (job-finished (job-id j) $data))
       (printf "job done!\n~a\n" data))))

;; ---------------------------------------------------------------------------------------------------
;; Observe interaction between task and job manager

(define (spawn-observer)
  (spawn
   (during (job-manager-alive)
     (during (task-manager $tm-id _)
       (define/query-set requests (task-assignment tm-id _ (task $tid _)) tid)
       (field [high-water-mark 0])
       (on (asserted (task-manager tm-id $slots))
           (when (> slots (high-water-mark))
             (high-water-mark slots)))
       (begin/dataflow
         (when (> (set-count (requests)) (high-water-mark))
           (log "!! DEMAND > SUPPLY !!")))))))

;; ---------------------------------------------------------------------------------------------------
;; Creating a Job

;; (Listof WorkDesc) -> (Values (Listof WorkDesc) (Optionof WorkDesc))
;; Pair up elements of the input list into a list of reduce tasks, and if the input list is odd also
;; return the odd-one out.
;; Conceptually, it does something like this:
;;   '(a b c d) => '((a b) (c d))
;;   '(a b c d e) => '((a b) (c d) e)
(define (pair-up ls)
  (let loop ([ls ls]
             [reductions '()])
    (match ls
      ['()
       (values reductions #f)]
      [(list x)
       (values reductions x)]
      [(list-rest x y more)
       (loop more (cons (reduce-work x y) reductions))])))


;; a TaskTree is one of
;;   (map-work data)
;;   (reduce-work TaskTree TaskTree)

;; (Listof String) -> TaskTree
;; Create a tree structure of tasks
(define (create-task-tree lines)
  (define map-works
    (for/list ([line (in-list lines)])
      (map-work line)))
  ;; build the tree up from the leaves
  (let loop ([nodes map-works])
    (match nodes
      ['()
       ;; input was empty
       (map-work "")]
      [(list x)
       x]
      [_
       (define-values (reductions left-over?)
         (pair-up nodes))
       (loop (if left-over?
                 (cons left-over? reductions)
                 reductions))])))

;; TaskTree -> (Listof Task)
;; flatten a task tree by assigning job-unique IDs
(define (task-tree->list tt)
  (define-values (tasks _)
    ;; TaskTree ID -> (Values (Listof Task) ID)
    ;; the input id is for the current node of the tree
    ;; returned id is the "next available" id, given ids are assigned in strict ascending order
    (let loop ([tt tt]
               [next-id 0])
      (match tt
        [(map-work _)
         (values (list (task next-id tt))
                       (add1 next-id))]
        [(reduce-work left right)
         (define left-id (add1 next-id))
         (define-values (lefts right-id)
           (loop left left-id))
         (define-values (rights next)
           (loop right right-id))
         (values (cons (task next-id (reduce-work left-id right-id))
                        (append lefts rights))
                 next)])))
  tasks)

;; InputPort -> Job
(define (create-job in)
  (define job-id (gensym 'job))
  (define input-lines (sequence->list (in-lines in)))
  (define tasks (task-tree->list (create-task-tree input-lines)))
  (job job-id tasks))

;; String -> Job
(define (string->job s)
  (create-job (open-input-string s)))

;; PathString -> Job
(define (file->job path)
  (define in (open-input-file path))
  (define j (create-job in))
  (close-input-port in)
  j)

(module+ test
  (test-case
      "two-line job parsing"
    (define input "a b c\nd e f")
    (define j (string->job input))
    (check-true (job? j))
    (match-define (job jid tasks) j)
    (check-true (id? jid))
    (check-true (list? tasks))
    (check-true (andmap task? tasks))
    (match tasks
      [(list-no-order (task rid (reduce-work left right))
                      (task mid1 (map-work data1))
                      (task mid2 (map-work data2)))
       (check-true (id? left))
       (check-true (id? right))
       (check-equal? (set left right) (set mid1 mid2))
       (check-equal? (set data1 data2)
                     (set "a b c" "d e f"))]
      [_
       (displayln tasks)]))
  (test-case
      "empty input"
    (define input "")
    (define j (string->job input))
    (check-true (job? j))
    (match-define (job jid tasks) j)
    (check-true (id? jid))
    (check-true (list? tasks))
    (check-equal? (length tasks) 1)
    (check-equal? (task-desc (car tasks))
                  (map-work ""))))


;; ---------------------------------------------------------------------------------------------------
;; Main

(define input "a b c a b c\na b\n a b\na b")
(define j (string->job input))
;; expected:
;; #hash((a . 5) (b . 5) (c . 2))

(spawn-client (file->job "lorem.txt"))
(spawn-job-manager)
(spawn-task-manager)
(spawn-task-runner)
(spawn-task-runner)
(spawn-observer)
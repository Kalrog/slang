; A self-interpreter: the Lisp of lisp.slang, written in itself.
; (main program a b) runs program's main with a and b, as run does.
; A program is a list of (define (name param ...) body); the environment
; is a list of (name . value) pairs.

(define (main program a b)
  (call program (lookup program 'main) (cons a (cons b '()))))

(define (lookup program name)
  (if (null? program)
      (error 'undefined-function)
      (if (eq? (car (car (cdr (car program)))) name)
          (car program)
          (lookup (cdr program) name))))

(define (params-of def) (cdr (car (cdr def))))
(define (body-of def) (car (cdr (cdr def))))

(define (call program def args)
  (ev program (body-of def) (bind (params-of def) args '())))

(define (bind names values env)
  (if (null? names)
      env
      (bind (cdr names) (cdr values) (cons (cons (car names) (car values)) env))))

(define (variable env x)
  (if (null? env)
      (error 'unbound-variable)
      (if (eq? (car (car env)) x)
          (cdr (car env))
          (variable (cdr env) x))))

(define (ev program e env)
  (if (symbol? e)
      (variable env e)
      (if (not (pair? e))
          e
          (let ((op (car e)) (args (cdr e)))
            (if (eq? op 'quote)
                (car args)
                (if (eq? op 'if)
                    (if (ev program (car args) env)
                        (ev program (car (cdr args)) env)
                        (ev program (car (cdr (cdr args))) env))
                    (if (eq? op 'let)
                        (ev-let program (car args) (car (cdr args)) env)
                        (apply program op (ev-args program args env)))))))))

(define (ev-let program bindings body env)
  (if (null? bindings)
      (ev program body env)
      (ev-let program (cdr bindings) body
              (cons (cons (car (car bindings)) (ev program (car (cdr (car bindings))) env)) env))))

(define (ev-args program es env)
  (if (null? es)
      '()
      (cons (ev program (car es) env) (ev-args program (cdr es) env))))

(define (apply program op args)
  (if (eq? op 'car) (car (car args))
  (if (eq? op 'cdr) (cdr (car args))
  (if (eq? op 'cons) (cons (car args) (car (cdr args)))
  (if (eq? op 'null?) (null? (car args))
  (if (eq? op 'pair?) (pair? (car args))
  (if (eq? op 'number?) (number? (car args))
  (if (eq? op 'symbol?) (symbol? (car args))
  (if (eq? op 'not) (not (car args))
  (if (eq? op 'eq?) (eq? (car args) (car (cdr args)))
  (if (eq? op '+) (+ (car args) (car (cdr args)))
  (if (eq? op '-) (- (car args) (car (cdr args)))
  (if (eq? op '*) (* (car args) (car (cdr args)))
  (if (eq? op '<) (< (car args) (car (cdr args)))
  (if (eq? op 'error) (error (car args))
  (call program (lookup program op) args))))))))))))))))

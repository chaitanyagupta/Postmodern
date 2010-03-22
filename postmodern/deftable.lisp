(in-package :postmodern)

(defvar *table-name*)
(setf (documentation '*table-name* 'variable)
      "Used inside deftable to find the name of the table being defined.")
(defvar *table-symbol*)
(setf (documentation '*table-name* 'variable)
      "Used inside deftable to find the symbol naming the table being defined.")

(defvar *tables* (make-hash-table)
  "Unexported table containing the known table definitions.")

(defmacro deftable (name &body definitions)
  "Define a table. name can be either a symbol or a (symbol string)
list. In the first case, the table name is derived from the symbol by
S-SQL's rules, in the second case, the name is given explicitly. The
body of definitions can contain anything that evaluates to a string,
as well as S-SQL expressions. In this body, the variables *table-name*
and *table-symbol* are bound to the relevant values."
  (multiple-value-bind (symbol name)
      (if (consp name) (values-list name) (values name (to-sql-name name nil)))
    (flet ((check-s-sql (form)
             (if (and (consp form) (keywordp (car form))) (list 'sql form) form)))
      `(progn
         (setf (gethash ',symbol *tables*)
               (lambda ()
                 (let ((*table-name* ,name) (*table-symbol* ',symbol))
                   (dolist (stat (list ,@(mapcar #'check-s-sql definitions)))
                     (execute stat)))))
         (values)))))

(defun create-table (name)
  "Create a defined table."
  (with-transaction ()
    (funcall (or (gethash name *tables*)
		 (error "No table '~a' defined." name)))
    (values)))

(defun create-all-tables ()
  "Create all defined tables."
  (maphash (lambda (name def) (declare (ignore name)) (funcall def)) *tables*))

(defun create-package-tables (package)
  "Create all tables whose identifying symbol is interned in the given
package."
  (let ((package (find-package package)))
    (maphash (lambda (name def)
               (when (eq (symbol-package name) package)
                 (funcall def)))
             *tables*)))

(labels ((index-name (fields)
           (make-symbol (format nil "~a-~{~a~^-~}-index" *table-name* fields)))
         (make-index (type fields)
           (sql-compile `(,type ,(index-name fields) :on ,*table-name* :fields ,@fields))))
  (defun \!index (&rest fields)
    "Used inside a deftable form. Define an index on the defined table."
    (make-index :create-index fields))
  (defun \!unique-index (&rest fields)
    "Used inside a deftable form. Define a unique index on the defined table."
    (make-index :create-unique-index fields)))

#+postmodern-use-mop
(defun \!dao-def ()
  "Used inside a deftable form. Define this table using the
corresponding DAO class' slots."
  (dao-table-definition *table-symbol*))

(defun \!foreign (target fields &rest target-fields/on-delete/on-update)
  "Used inside a deftable form. Define a foreign key on this table.
Pass a table the index refers to, a list of fields or single field in
*this* table, and, if the fields have different names in the table
referred to, another field or list of fields for the target table."
  (let* ((args target-fields/on-delete/on-update)
         (target-fields (and args (not (keywordp (car args))) (pop args))))
    (labels ((fkey-name (target fields)
               (to-sql-name (format nil "~a_~a_~{~a~^_~}_foreign" *table-name* target fields))))
      (unless (listp fields) (setf fields (list fields)))
      (unless (listp target-fields) (setf target-fields (list target-fields)))
      (let* ((target-name (to-sql-name target))
             (field-names (mapcar #'to-sql-name fields))
             (target-names (if target-fields (mapcar #'to-sql-name target-fields) field-names)))
        (format nil "ALTER TABLE ~a ADD CONSTRAINT ~a FOREIGN KEY (~{~a~^, ~}) REFERENCES ~a (~{~a~^, ~}) ~@[ON DELETE ~a~] ~@[ON UPDATE ~a~]"
                *table-name* (fkey-name target fields) field-names target-name target-names
                (s-sql::expand-foreign-on* (getf args :on-delete))
                (s-sql::expand-foreign-on* (getf args :on-update)))))))

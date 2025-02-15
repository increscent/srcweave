; Copyright (c) 2022 Justin Meiners
; 
; This program is free software: you can redistribute it and/or modify  
; it under the terms of the GNU General Public License as published by  
; the Free Software Foundation, version 2.
;
; This program is distributed in the hope that it will be useful, but 
; WITHOUT ANY WARRANTY; without even the implied warranty of 
; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU 
; General Public License for more details.
;
; You should have received a copy of the GNU General Public License 
; along with this program. If not, see <http://www.gnu.org/licenses/>.

(in-package :srcweave)

; Weave: Make  document from lit file.

; DESIGN
; One-to-one correspondence between .lit and .html files.
; The body of an .html file should look the same regardless of whether the .lit
; is in another context (like a book).

(defstruct weaver 
  (def-table (make-hash-table :test #'equal) :type hash-table)
  (use-table (make-hash-table :test #'equal) :type hash-table)
  (initial-def-table (make-hash-table :test #'equal) :type hash-table)

  (toc nil :type list)
  (title nil :type (or string null))
  (section-counter -1 :type number)
  (chapter-counter -1 :type number)
  (code-type-table (make-hash-table :test #'equal) :type hash-table)
  (used-extensions nil :type list)
  (used-math nil :type boolean))

(defun lit-page-filename (filename)
  (concatenate 'string
               (uiop:split-name-type filename)
               ".html"))

(defun make-weaver-default (file-defs)
  (let ((all-defs (alexandria-2:mappend #'cdr file-defs)))
    (make-weaver
      :def-table (textblockdef-create-table all-defs)
      :use-table (textblockdef-create-use-table (remove-if-not
                                                  (lambda (def) (eq (textblockdef-kind def) :CODE))
                                                  all-defs)) 
      :initial-def-table (textblockdef-create-title-to-initial-table all-defs)
      :toc (create-global-toc file-defs)
      :code-type-table (codetable-create))))


(defun chapter-id (index) (format nil "c~a" index))
(defun section-id (section-index chapter-index) (format nil "s~a:~a" chapter-index section-index))

(defun block-anchor (block-id &optional file)  (format nil "~a#~a"  (or file "") block-id))

(defun block-anchor2 (def current-file)
  (block-anchor (textblockdef-id def)
                (if (equal current-file (textblockdef-file def))
                    nil
                    (lit-page-filename (textblockdef-file def)))))

(defun weave-include (title current-file weaver code-style)
  (multiple-value-bind (initial-def-id present)
      (gethash (textblock-slug title) (weaver-initial-def-table weaver))
    (when (not present)
      (error 'user-error
             :format-control "attempting to include unknown block ~S"
             :format-arguments (list title)))

    (let ((other (gethash initial-def-id (weaver-def-table weaver))))
      (format t "<em class=\"block-link nocode\" title=\"~a:~a\">"
              (textblockdef-file other)
              (+ (textblockdef-line-number other) 1))
      (when (textblockdef-weavable other)
        (format t "<a href=\"~a\">" (block-anchor2 other current-file)))
      (format t
              (if code-style
                  "@{~a}"
                  "~a")
              title)
      (when (textblockdef-weavable other)
        (write-string "</a>"))
      (write-string "</em>"))))

(defparameter *html-replace-list*
  '((#\& . "&amp;") (#\< . "&lt;") (#\> . "&gt;")))

(defun escape-html (string)
  (reduce (lambda (string replace-pair)
            (ppcre:regex-replace-all (car replace-pair) string (cdr replace-pair)))
          *html-replace-list*
          :initial-value string))

(defun weave-code-line (weaver line def)
  (loop for expr in line do
        (cond ((stringp expr) (write-string (escape-html expr))) 
              ((commandp expr) 
               (case (first expr)
                 (:INCLUDE (weave-include
                             (second expr)
                             (textblockdef-file def)
                             weaver
                             t))
                 (otherwise
                   (format *error-output* "warning: unknown code command ~S~%" (first expr)))))
              (t (error "unknown structure ~S" expr)))))

(defun weave-uses (weaver def)
  (let ((uses 
          (mapcar (lambda (slug)
                    (gethash slug (weaver-def-table weaver)))
                  (gethash (textblock-slug (textblockdef-title def))
                           (weaver-use-table weaver)))))
    (when (not (null uses))
      (write-string "<p class=\"block-usages\"><small>Used by ")
      (mapnil-indexed (lambda (other i)
                        (if (textblockdef-weavable other)
                            (format t "<a href=\"~a\" title=\"~a:~a ~a\">~a</a> "
                                    (block-anchor2 other (textblockdef-file def))
                                    (textblockdef-file other)
                                    (+ 1 (textblockdef-line-number other))
                                    (textblockdef-title other)
                                    (+ i 1))
                            (format t "<span title=\"~a:~a ~a\">~a</span> "
                                    (textblockdef-file other)
                                    (+ 1 (textblockdef-line-number other))
                                    (textblockdef-title other)
                                    (+ i 1)))) uses)
      (write-string "</small></p>"))))

(defun language-to-class (language)
  (if (equal language "text") "" language))

(defun operation-string (op)
  (case op
    (:DEFINE nil)
    (:APPEND "+=")
    (:REDEFINE ":=")
    (otherwise (string op))))

(defun weave-operation (weaver def)
  (alexandria-2:when-let ((symbol (operation-string (textblockdef-operation def))))
  (format t " <a href=\"~a\">~a</a>"
          (block-anchor2
             (gethash (gethash (textblockdef-title-slug def) (weaver-initial-def-table weaver))
                      (weaver-def-table weaver)) 
             (textblockdef-file def))
          symbol)))

(defun weave-codedef (weaver def)
  ; record extensions
  (when (textblockdef-is-file def)
    (alexandria-2:when-let ((extension (pathname-type (textblockdef-title def))))
                           (push extension (weaver-used-extensions weaver))))

  (write-line "<div class=\"code-block\">")

  ; write header
  (let* ((title (textblockdef-title def))
         (id (textblockdef-id def)))

    (write-line "<span class=\"block-header\">")
    (format t "<strong class=\"block-title\"><em><a id=\"~a\" href=\"#~a\">~a</a></em></strong>"
            id
            id
            title)
    (weave-operation weaver def)
    (write-line "</span>"))

  ; write body
  (let* ((block (textblockdef-block def))
         (lines (textblock-lines block)))
    (format t "<pre class=\"prettyprint\"><code class=\"~a\">"
            (language-to-class (textblockdef-language def)))

    ; trim blank lines from start and end
    (loop for i 
          from (position-if-not #'null lines)
          to (position-if-not #'null lines :from-end t) do
          (weave-code-line weaver (aref lines i) def)
          (write-line ""))

    (write-line "</code></pre>"))
    (when (eq :DEFINE (textblockdef-operation def))
      (weave-uses weaver def))
  (write-line "</div>"))

(defun weave-prose-line (weaver line def)
  (loop for expr in line do
        (cond ((stringp expr) (write-string expr)) 
              ((commandp expr) 
               (case (first expr)
                 (:INCLUDE (weave-include
                            (second expr)
                            (textblockdef-file def)
                            weaver
                            nil))
                 (:TITLE
                  (setf (weaver-title weaver)
                        (second expr)))
                 (:C
                  ; Also can act as a title
                  (when (null (weaver-title weaver))
                    (setf (weaver-title weaver)
                          (second expr)))
                  (incf (weaver-chapter-counter weaver))
                  (setf (weaver-section-counter weaver) -1)
                  (format t "<h1>~a<a id=\"~a\"></a></h1>~%" 
                          (second expr)
                          (chapter-id (weaver-chapter-counter weaver))))
                 (:S
                  (incf (weaver-section-counter weaver))
                  (format t "<h2>~a. ~a<a id=\"~a\"></a></h2>~%" 
                          (+ (weaver-section-counter weaver) 1)
                          (second expr)
                          (section-id 
                            (weaver-section-counter weaver)
                            (weaver-chapter-counter weaver))))
                 (:CODE_TYPE
                  (let* ((args (split-whitespace (second expr)))
                         (language (first args))
                         (extension (subseq (second args) 1)))
                    (setf (gethash extension (weaver-code-type-table weaver)) language)
                    (push extension (weaver-used-extensions weaver))))
                 (:COMMENT_TYPE nil)
                 (:ADD_CSS nil)
                 (:OVERWRITE_CSS nil)
                 (:COLORSCHEME nil)
                 (:ERROR_FORMAT nil)
                 (:MATHBLOCK
                  (setf (weaver-used-math weaver) t)
                  (write-string "<div class=\"math-block\">")
                  (when (not (equal (second expr) "displaymath"))
                      (format t "\\begin{~a}" (second expr)))
                  (write-separated-list (third expr) #\newline *standard-output*)
                  (when (not (equal (second expr) "displaymath"))
                      (format t "\\end{~a}" (second expr)))
                  (write-string "</div>"))
                 (:MATH
                  (setf (weaver-used-math weaver) t)
                  (format t "<span class=\"math\">~a</span>"
                          (second expr)))
                 (:TOC (weave-toc
                         (weaver-toc weaver)
                         (textblockdef-file def)))
                 (otherwise (error 'user-error
                                   :format-control "unknown prose command ~S"
                                   :format-arguments (first expr)))))
              (t (error "unknown structure ~s" expr)))))

(defun weave-prosedef (weaver def)
   (let ((block (textblockdef-block def))
         (current-file (textblockdef-file def)))

     (loop for line across (textblock-lines block) do
           (weave-prose-line weaver line def)
           (write-line ""))))

(defun weave-blocks (weaver source-defs)
    (dolist (def source-defs)
      (when (textblockdef-weavable def)
        (if (eq (textblockdef-kind def) :CODE)
            (weave-codedef weaver def)
            (weave-prosedef weaver def)))))

(defun weave-html (weaver stream source-defs)
  (write-line "<!-- Generated by srcweave https://github.com/justinmeiners/srcweave -->" stream)
  (finish-output stream)
  ; Run markdown on the entire document so named links work.
  (let ((md (uiop:launch-program
              (list *markdown-command*)
              :input :stream 
              :output stream
              :error-output *error-output*)))

    (let ((*standard-output* (uiop:process-info-input md)))
      (weave-blocks weaver source-defs))
    (uiop:close-streams md)
    (uiop:wait-process md)))

(defun weave-path (weaver source-defs output-path)
  (with-open-file (output-stream output-path
                     :direction :output
                     :if-exists :supersede
                     :if-does-not-exist :create)  

    (if (not (stringp *format-command*))
        (weave-html weaver output-stream source-defs)   

        ; we first write to data in RAM to get formatting info for environment variables.
        (let ((text (with-output-to-string (s)
                      (weave-html weaver s source-defs))))
          (setf (uiop:getenv "LIT_TYPES")
                (extensions-to-type-string (weaver-code-type-table weaver)
                                           (weaver-used-extensions weaver)))
          (setf (uiop:getenv "LIT_TITLE") (or (weaver-title weaver) ""))
          (setf (uiop:getenv "LIT_MATH") (if (weaver-used-math weaver) "1" ""))

          (uiop:run-program (split-whitespace *format-command*)
                            :output output-stream
                            :error-output t
                            :input (make-string-input-stream text)))) ))

(defun weave (file-defs output-dir)
  (let* ((weaver (make-weaver-default file-defs)))
    (map nil (lambda (path-defs-pair)
               (let* ((input-path (car path-defs-pair))
                      (defs (cdr path-defs-pair))
                      (output-path (merge-pathnames output-dir (make-pathname
                                                           :name (pathname-name input-path)
                                                           :type "html"))))

                 (progn
                   (format t "writing doc: ~a~%" output-path)
                   (ensure-directories-exist output-path)
                   (weave-path
                     weaver
                     defs
                     output-path))))
         file-defs)))


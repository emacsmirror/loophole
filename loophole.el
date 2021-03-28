;;; loophole.el --- Manage temporary key bindings in Emacs

;; Copyright (C) 2020 0x60DF

;; Author: 0x60DF <0x60df@gmail.com>
;; Created: 30 Aug 2020
;; Version: 0.1.0
;; Keywords: convenience
;; URL: https://github.com/0x60df/loophole

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Loophole provides temporary key bindings management feature.
;; Keys can be set by interactive interface in disposable keymaps
;; which are automatically generated for temporary use.

;;; Code:

(require 'seq)
(require 'kmacro)

(defgroup loophole nil
  "Manage temporary key bindings."
  :group 'convenience)

(defvar loophole-map-alist nil
  "Alist of keymaps for loophole.
Syntax is same as `minor-mode-map-alist', i.e. each element
looks like (STATE-VARIABLE . KEYMAP).  STATE-VARIABLE is a
symbol whose boolean value represents if the KEYMAP is
active or not.  KEYMAP is a keymap object.")

(defvar loophole-map-editing nil
  "When non-nil, Loophole binds keys in the existing keymap.
Specifically, the first entry of `loophole-map-alist' is
used for the binding.")

(defcustom loophole-temporary-map-max 8
  "Maximum number of temporary keymap.
When the number of temporary keymap has already been reached
to `loophole-temporary-map-max', `loophole-generate-map'
overwrites the earliest used one."
  :group 'loophole
  :type 'integer)

(defcustom loophole-allow-keyboard-quit t
  "If non-nil, binding commands can be quit even while reading keys."
  :group 'loophole
  :type 'boolean)

(defcustom loophole-kmacro-completing-key (where-is-internal
                                           'keyboard-quit nil t)
  "Key sequence to complete definition of keyboard macro."
  :group 'loophole
  :type 'key-sequence)

(defcustom loophole-bind-command-order
  '(loophole-obtain-key-and-command-by-symbol
    loophole-obtain-key-and-command-by-key-sequence)
  "The priority list of methods to obtain key and command for binding.
`loophole-bind-command' refers this variable to select
obtaining method.
First element gets first priority.
Each element should return a list looks like (key command)."
  :group 'loophole
  :type '(repeat symbol))

(defcustom loophole-bind-kmacro-order
  '(loophole-obtain-key-and-kmacro-by-recursive-edit
    loophole-obtain-key-and-kmacro-by-read-key
    loophole-obtain-key-and-kmacro-by-recall-record)
  "The priority list of methods to obtain key and kmacro for binding.
`loophole-bind-kmacro' refers this variable to select
obtaining method.
First element gets first priority.
Each element should return a list looks like (key kmacro)."
  :group 'loophole
  :type '(repeat symbol))

(defcustom loophole-set-key-order
  '(loophole-obtain-key-and-command-by-symbol
    loophole-obtain-key-and-kmacro-by-recursive-edit
    loophole-obtain-key-and-command-by-key-sequence
    loophole-obtain-key-and-kmacro-by-read-key
    loophole-obtain-key-and-kmacro-by-recall-record)
  "The priority list of methods to obtain key and object for binding.
`loophole-set-key' refers this to select obtaining method.
First element gets first priority.
Each element should return a list looks like (key object)."
  :group 'loophole
  :type '(repeat symbol))

(defcustom loophole-mode-lighter-base " L"
  "Lighter base string for mode line."
  :group 'loophole
  :type 'string)

(defcustom loophole-mode-lighter-editing-sign "+"
  "Lighter editing sign string for mode line."
  :group 'loophole
  :type 'string)

(defun loophole-map-variable-list ()
  "Return list of all keymap variables for loophole.
Elements are ordered according to `loophole-map-alist'."
  (mapcar (lambda (e)
            (get (car e) :loophole-map-variable))
          loophole-map-alist))

(defun loophole-state-variable-list ()
  "Return list of all keymap variables for loophole.
Elements are ordered according to `loophole-map-alist'."
  (mapcar #'car loophole-map-alist))

(defun loophole-key-equal (k1 k2)
  "Return t if two key sequences K1 and K2 are equivalent.
Specifically, this function get `key-description' of each
key, and compare them by `equal'."
  (equal (key-description k1) (key-description k2)))

(defun loophole-read-key (prompt)
  "Read and return key sequence for bindings.
PROMPT is a string for reading key."
  (let* ((menu-prompting nil)
         (key (read-key-sequence prompt nil t)))
    (or (vectorp key) (stringp key)
        (signal 'wrong-type-argument (list 'arrayp key)))
    (and loophole-allow-keyboard-quit
         (loophole-key-equal
          (vconcat (where-is-internal 'keyboard-quit nil t))
          (vconcat key))
         (keyboard-quit))
    key))

(defun loophole-start-edit ()
  "Start keymap edit session."
  (interactive)
  (setq loophole-map-editing t))

(defun loophole-stop-edit ()
  "Stop keymap edit session."
  (interactive)
  (setq loophole-map-editing nil))

(defun loophole-start-kmacro ()
  "Start defining keyboard macro.
Definition can be finished by calling `loophole-end-kmacro'."
  (interactive)
  (loophole-mode 1)
  (kmacro-start-macro nil)
  (let* ((complete (where-is-internal 'loophole-end-kmacro nil t))
         (abort (where-is-internal 'loophole-abort-kmacro nil t))
         (body (if (and complete abort)
                   (format "[Complete: %s, Abort: %s]"
                           (key-description complete)
                           (key-description abort))
                 "[loophole-end/abort-kmacro should be bound to key]")))
    (message "Defining keyboard macro... %s" body))
  (if (not (called-interactively-p 'any))
      (recursive-edit)))

(defun loophole-end-kmacro ()
  "End defining keyboard macro."
  (interactive)
  (unwind-protect
      (kmacro-end-macro nil)
    (if (not (zerop (recursion-depth)))
        (exit-recursive-edit))))

(defun loophole-abort-kmacro ()
  "Abort defining keyboard macro."
  (interactive)
  (if (not (zerop (recursion-depth)))
      (abort-recursive-edit))
  (keyboard-quit))

(defun loophole-generate-map ()
  "Generate temporary keymap which holds temporary key bindings.
Generated keymap is stored in variable whose name is
loophole-n-map, and this function returns this variable.
If the number of temporary keymap has been reached to
`loophole-temporary-map-max', earliest used one is overwritten."
  (letrec ((find-nonbound-temporary-map-variable
            (lambda (i)
              (let ((s (intern (format "loophole-%d-map" i))))
                (cond ((< loophole-temporary-map-max i) nil)
                      ((boundp s)
                       (funcall find-nonbound-temporary-map-variable (+ i 1)))
                      (t s))))))
    (let* ((nonbound-temporary-map-variable
            (funcall find-nonbound-temporary-map-variable 1))
           (earliest-used-disabled-temporary-map-variable
            (seq-find (lambda (map-variable)
                        (and (not (symbol-value
                                   (get map-variable :loophole-state-variable)))
                             (string-match
                              "loophole-[0-9]+-map"
                              (symbol-name map-variable))))
                      (reverse (loophole-map-variable-list))))
           (map-variable (or nonbound-temporary-map-variable
                             earliest-used-disabled-temporary-map-variable
                             'loophole-1-map)))
      (set map-variable (make-sparse-keymap))
      map-variable)))

(defun loophole-generate-state (map-variable)
  "Generate state for MAP-VARIABLE and assign to state variable.
This function returns this state variable."
  (let ((state-variable (intern (concat (symbol-name map-variable) "-state"))))
    (set state-variable nil)
    state-variable))

(defun loophole-register (map-variable state-variable &optional tag)
  "Register the set of MAP-VARIABLE and STATE-VARIABLE to loophole.
Optional argument TAG is tag string which may be shown in
mode line."
  (put map-variable :loophole-state-variable state-variable)
  (put state-variable :loophole-map-variable map-variable)
  (put map-variable :loophole-tag tag)
  (push `(,state-variable . ,(symbol-value map-variable)) loophole-map-alist))

(defun loophole-registered-p (map-variable &optional state-variable)
  "Return non-nil if MAP-VARIABLE is registered to loophole.
If optional argument STATE-VARIABLE is not nil,
Return non-nil if both MAP-VARIABLE and STATE-VARIABLE are
registered, and they are associated."
  (and (if state-variable
           (eq state-variable (get map-variable :loophole-state-variable))
         (setq state-variable (get map-variable :loophole-state-variable)))
       (eq map-variable (get state-variable :loophole-map-variable))
       (assq state-variable loophole-map-alist)))

(defun loophole-prioritize-map (map-variable)
  "Give first priority to MAP-VARIABLE.
This is done by move the entry in `loophole-map-alist' to
the front.  If precedence is changed, quit current editing
session."
  (let ((state-variable (get map-variable :loophole-state-variable)))
    (when state-variable
      (unless (eq (assq state-variable loophole-map-alist)
                  (car loophole-map-alist))
        (setq loophole-map-alist
              (assq-delete-all state-variable loophole-map-alist))
        (push `(,state-variable . ,(symbol-value map-variable))
              loophole-map-alist)
        (loophole-stop-edit)))))

(defun loophole-ready-map ()
  "Return available temporary keymap.
If Currently editing keymap exists, return it; otherwise
generate new one and return it."
  (cond (loophole-map-editing
         (set (caar loophole-map-alist) t)
         (cdar loophole-map-alist))
        (t (let* ((map-variable (loophole-generate-map))
                  (state-variable (loophole-generate-state map-variable)))
             (if (not (loophole-registered-p map-variable state-variable))
                 (loophole-register map-variable state-variable
                                    (replace-regexp-in-string
                                     "loophole-\\([0-9]+\\)-map" "\\1"
                                     (symbol-name map-variable)))
               (loophole-prioritize-map map-variable))
             (set state-variable t)
             (symbol-value map-variable)))))

(defun loophole-enable-map (map-variable &optional set-state-only)
  "Enable the keymap stored in MAP-VARIABLE.

In addition to setting t for the state of MAP-VARIABLE,
this function prioritizes MAP-VARIABLE, and enables
`loophole-mode'.
If optional argument SET-STATE-ONLY is non-nil,
this function does not do anything except for setting state.

When interactive call, prefix argument is directly assigned
to SET-STATE-ONLY."
  (interactive
   (let ((disabled-map-variable-list
          (seq-filter (lambda (map-variable)
                        (not (symbol-value (get map-variable
                                                :loophole-state-variable))))
                      (loophole-map-variable-list))))
     (list
      (cond (disabled-map-variable-list
             (intern (completing-read "Enable keymap temporarily: "
                                      disabled-map-variable-list)))
            (t (message "There are no disabled loophole maps.")
               nil))
      current-prefix-arg)))
  (if map-variable
      (let ((state-variable (get map-variable :loophole-state-variable)))
        (when state-variable
          (set state-variable t)
          (unless set-state-only
            (loophole-prioritize-map map-variable)
            (loophole-mode 1))))))

(defun loophole-disable-map (map-variable &optional set-state-only)
  "Disable the keymap stored in MAP-VARIABLE.

In addition to setting nil for the state of MAP-VARIABLE,
this function stops editing if MAP-VARIABLE is the first
element of `loophole-map-alist',
and disables `loophole-mode' if MAP-VARIABLE is the only
one enabled keymap.
If optional argument SET-STATE-ONLY is non-nil,
this function does not do anything except for setting state.

When interactive call, prefix argument is directly assigned
to SET-STATE-ONLY."
  (interactive
   (let ((enabled-map-variable-list
          (seq-filter (lambda (map-variable)
                        (symbol-value (get map-variable
                                           :loophole-state-variable)))
                      (loophole-map-variable-list))))
     (list
      (cond (enabled-map-variable-list
             (intern (completing-read "Disable keymap temporarily: "
                                      enabled-map-variable-list)))
            (t (message "There are no enabled loophole maps.")
               nil))
      current-prefix-arg)))
  (if map-variable
      (let ((state-variable (get map-variable :loophole-state-variable)))
        (when state-variable
          (set state-variable nil)
          (unless set-state-only
            (if (eq (assq state-variable loophole-map-alist)
                    (car loophole-map-alist))
                (loophole-stop-edit))
            (unless (seq-find #'symbol-value (loophole-state-variable-list))
              (loophole-mode -1)))))))

(defun loophole-disable-last-map ()
  "Disable the lastly enabled keymap.
Stopping edit and disabling `loophole-mode' may occur
according to the same rule as `loophole-disable-map'."
  (interactive)
  (let* ((state-variable
          (seq-find #'symbol-value (loophole-state-variable-list)))
         (map-variable (get state-variable :loophole-map-variable)))
    (if map-variable (loophole-disable-map map-variable))))

(defun loophole-disable-all-maps ()
  "Disable the all keymaps.
This function also stops editing but keeps `loophole-mode'
enabled."
  (interactive)
  (mapc (lambda (map-variable)
          (loophole-disable-map map-variable 'set-state-only))
        (loophole-map-variable-list))
  (loophole-stop-edit))

(defun loophole-obtain-key-and-object ()
  "Return set of key and any Lisp object.
Object is obtained as return value of `eval-minibuffer'."
  (let* ((menu-prompting nil)
         (key (loophole-read-key "Set key temporarily: ")))
    (list key (eval-minibuffer (format "Set key %s to entry: "
                                       (key-description key))))))

(defun loophole-obtain-key-and-command-by-symbol ()
  "Return set of key and command obtained by reading minibuffer."
  (let* ((menu-prompting nil)
          (key (loophole-read-key "Set key temporarily: ")))
    (list key (read-command (format "Set key %s to command: "
                                    (key-description key))))))

(defun loophole-obtain-key-and-command-by-key-sequence ()
  "Return set of key and command obtained by key sequence lookup."
  (let* ((menu-prompting nil)
         (key (loophole-read-key "Set key temporarily: ")))
    (list key (let ((binding
                     (key-binding (loophole-read-key
                                   (format
                                    "Set key %s to command bound for: "
                                    (key-description key))))))
                (message "%s" binding)
                binding))))

(defun loophole-obtain-key-and-kmacro-by-read-key ()
  "Return set of key and kmacro obtained by reading key.
This function `read-key' recursively.  If you are finished
keyboard macro, type `loophole-kmacro-completing-key'.
By default, `loophole-kmacro-completing-key' is \\[keyboard-quit]
the key bound to `keyboard-quit'.  In this situation, you
cannot use \\[keyboard-quit] for quitting.
Once `loophole-kmacro-completing-key' is changed, you can
complete definition of kmacro by new completing key, and
\\[keyboard-quit] takes effect as quit."
  (let ((complete (vconcat loophole-kmacro-completing-key))
        (quit (vconcat (where-is-internal 'keyboard-quit nil t))))
    (or (vectorp complete)
        (stringp complete)
        (vectorp quit)
        (stringp quit)
        (user-error "Neither completing key nor quitting key is invalid"))
    (let* ((menu-prompting nil)
           (key (loophole-read-key "Set key temporarily: ")))
      (list
       key
       (letrec
           ((read-arbitrary-key-sequence
             (lambda (v)
               (let* ((k (vector
                          (read-key
                           (format "Set key %s to kmacro: (%s to complete) [%s]"
                                   (key-description key)
                                   (key-description complete)
                                   (mapconcat (lambda (e)
                                                (key-description (vector e)))
                                              (reverse v)
                                              " ")))))
                      (v (vconcat k v)))
                 (cond ((loophole-key-equal
                         (seq-take v (length complete))
                         complete)
                        (reverse (seq-drop v (length complete))))
                       ((loophole-key-equal
                         (seq-take v (length quit))
                         quit)
                        (keyboard-quit))
                       (t (funcall read-arbitrary-key-sequence v)))))))
         (funcall read-arbitrary-key-sequence nil))))))

(defun loophole-obtain-key-and-kmacro-by-recursive-edit ()
  "Return set of key and kmacro obtained by recursive edit.
\\<loophole-mode-map>
This function enter recursive edit in order to offer
keyboard macro defining work space.  Definition can be
finished by calling `loophole-end-kmacro' which is bound to
\\[loophole-end-kmacro].
Besides, Definition can be aborted by calling
`loophole-end-kmacro' which is bound to \\[loophole-abort-kmacro]."
  (let* ((menu-prompting nil)
          (key (loophole-read-key "Set key temporarily: ")))
    (list key (progn (loophole-start-kmacro)
                     last-kbd-macro))))

(defun loophole-obtain-key-and-kmacro-by-recall-record ()
  "Return set of key and kmacro obtained by recalling record."
  (let* ((menu-prompting nil)
          (key (loophole-read-key "Set key temporarily: ")))
    (list key (completing-read (format "Set key %s to kmacro: "
                                       (key-description (kbd "C-a")))
                               (mapcar #'car (remq nil (cons (kmacro-ring-head)
                                                             kmacro-ring)))
                               nil t))))

(defun loophole-prefix-rank-value (arg)
  "Return rank value for raw prefix argument ARG.
In the context of this function rank of prefix argument is
defined as follows.
The rank of no prefix argument is 0.
The rank of prefix argument specified by C-u and C-1 is 1,
The rank of C-u C-u and C-2 is 2,
Likewise, rank n means C-u * n or C-n."
  (cond ((null arg) 0)
        ((listp arg) (truncate (log (prefix-numeric-value arg) 4)))
        ((natnump arg) arg)
        (t 0)))

(defun loophole-bind-entry (key entry &optional keymap define-key-only)
  "Bind KEY to ENTRY temporarily.
Any Lisp object is acceptable for ENTRY, but only few types
make sense.  Meaningful types of ENTRY is completely same as
general keymap entry.

By default, KEY is bound in the currently editing keymap or
generated new one.  If optional argument KEYMAP is non-nil,
and it is registered to loophole, KEYMAP is used instead.

If optional argument DEFINE-KEY-ONLY is non-nil, this
function only call `define-key', otherwise this function
call some other functions as follows.  In any case,
`loophole-start-edit', and turn on `loophole-mode'.
If KEYMAP is non-nil `loophole-prioritize-map'."
  (interactive (loophole-obtain-key-and-object))
  (if keymap
      (let* ((state-variable (car (rassq keymap loophole-map-alist)))
             (map-variable (get state-variable :loophole-map-variable)))
        (if (not (and keymap
                      map-variable
                      (loophole-registered-p map-variable)
                      (eq (symbol-value map-variable) keymap)))
            (error "Invalid keymap: %s" keymap)
          (define-key keymap key entry)
          (unless define-key-only
            (loophole-prioritize-map map-variable))))
    (define-key (loophole-ready-map) key entry))
  (unless define-key-only
    (loophole-start-edit)
    (loophole-mode 1)))

(defun loophole-bind-command (key command &optional keymap define-key-only)
  "Bind KEY to COMMAND temporarily.
This function finally calls `loophole-bind-entry', so that
The keymap used for binding and the meaning of optional
arguments KEYMAP, and DEFINE-KEY-ONLY are same as
`loophole-bind-entry'.See docstring of `loophole-bind-entry'
for more details.

When called interactively, this function determine
obtaining method for KEY and COMMAND according to
`loophole-bind-command-order'.
When this function called without prefix argument,
the first element of `loophole-bind-command-order' is
employed as obtaining method.
C-u and C-1 invokes the second element,
C-u C-u and C-2 invokes the third one.
Likewise C-u * n and C-n invoke the nth element."
  (interactive
   (let* ((n (loophole-prefix-rank-value current-prefix-arg))
          (obtaining-method (elt loophole-bind-command-order n)))
     (if (null obtaining-method)
         (user-error "Undefined prefix argument"))
     (funcall obtaining-method)))
  (if (commandp command)
      (loophole-bind-entry key command keymap define-key-only)
    (error "Invalid command: %s" command)))

(defun loophole-bind-kmacro (key kmacro &optional keymap define-key-only)
  "Bind KEY to KMACRO temporarily.
This function finally calls `loophole-bind-entry', so that
the keymap used for binding and the meaning of optional
arguments KEYMAP, and DEFINE-KEY-ONLY are same as
`loophole-bind-entry'.See docstring of `loophole-bind-entry'
for more details.

When called interactively, this function determine
obtaining method for KEY and KMACRO according to
`loophole-bind-kmacro-order'.
When this function is called without prefix argument,
the first element of `loophole-bind-kmacro-order' is
employed as obtaining method.
C-u and C-1 invokes the second element,
C-u C-u and C-2 invokes the third one.
Likewise C-u * n and C-n invoke the nth element."
  (interactive
   (let* ((n (loophole-prefix-rank-value current-prefix-arg))
          (obtaining-method (elt loophole-bind-kmacro-order n)))
     (if (null obtaining-method)
         (user-error "Undefined prefix argument"))
     (funcall obtaining-method)))
  (if (or (vectorp kmacro)
          (stringp kmacro)
          (kmacro-p kmacro))
      (loophole-bind-entry key kmacro keymap define-key-only)
    (error "Invalid kmacro: %s" kmacro)))

(defun loophole-bind-last-kmacro (key)
  "Bind KEY to the lastly accessed keyboard macro.
Currently editing keymap or generated new one is used for
binding."
  (interactive
   (let* ((menu-prompting nil)
          (key (loophole-read-key "Set key temporarily: ")))
     (list key)))
  (loophole-bind-kmacro key (kmacro-lambda-form (kmacro-ring-head))))

(defun loophole-set-key (key entry)
  "Set the temporary binding for KEY and ENTRY.
This function finally calls `loophole-bind-entry', so that
The keymap used for binding is the same as
`loophole-bind-entry', i.e. currently editing keymap or
generated new one.  ENTRY is also same as
`loophole-bind-entry'.  Any Lisp object is acceptable for
ENTRY, although only few types make sense.  Meaningful types
of ENTRY is completely same as general keymap entry.

When called interactively, this function determine
obtaining method for KEY and ENTRY according to
`loophole-set-key-order'.
When this function is called without prefix argument,
the first element of `loophole-set-key-order' is
employed as obtaining method.
C-u and C-1 invokes the second element,
C-u C-u and C-2 invokes the third one.
Likewise C-u * n and C-n invoke the nth element."
  (interactive
   (let* ((n (loophole-prefix-rank-value current-prefix-arg))
          (obtaining-method (elt loophole-set-key-order n)))
     (if (null obtaining-method)
         (user-error "Undefined prefix argument"))
     (funcall obtaining-method)))
  (loophole-bind-entry key entry))

(defun loophole-unset-key (key)
  "Unset the temporary biding of KEY."
  (interactive "kUnset key temporarily: ")
  (if loophole-map-editing
      (define-key (cdar loophole-map-alist) key nil)))

(defun loophole-quit ()
  "Quit loophole completely.
Disable the all keymaps, and turn off `loophole-mode'."
  (interactive)
  (loophole-disable-all-maps)
  (loophole-mode -1))

(define-minor-mode loophole-mode
  "Toggle temporary key bindings (Loophole mode).

When Loophole mode is enabled, active loophole maps
i.e. keymaps registered as temporary use and whose state is
not nil, take effect.

Loophole mode also offers the bindings for the
temporary key bindings management command.

\\{loophole-mode-map}"
  :group 'loophole
  :global t
  :lighter (""
            loophole-mode-lighter-base
            (loophole-map-editing loophole-mode-lighter-editing-sign)
            (:eval (let ((n (length
                             (delq nil
                                   (mapcar
                                    (lambda (e) (symbol-value (car e)))
                                    loophole-map-alist)))))
                     (if (zerop n)
                         ""
                       (format ":%d" n)))))
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c \\") #'loophole-mode)
            (define-key map (kbd "C-c ,") #'loophole-disable-last-map)
            (define-key map (kbd "C-c .") #'loophole-quit)
            (define-key map (kbd "C-c /") #'loophole-stop-edit)
            (define-key map (kbd "C-c ?") #'loophole-start-edit)
            (define-key map (kbd "C-c [") #'loophole-set-key)
            (define-key map (kbd "C-c ]") #'loophole-unset-key)
            (define-key map (kbd "C-c +") #'loophole-enable-map)
            (define-key map (kbd "C-c -") #'loophole-disable-map)
            (define-key map (kbd "C-c _") #'loophole-disable-all-maps)
            (define-key map (kbd "C-c (") #'loophole-start-kmacro)
            (define-key map (kbd "C-c )") #'loophole-end-kmacro)
            (define-key map (kbd "C-c !") #'loophole-abort-kmacro)
            (define-key map (kbd "C-c =") #'loophole-bind-last-kmacro)
            (define-key map (kbd "C-c @") #'loophole-bind-entry)
            (define-key map (kbd "C-c #") #'loophole-bind-command)
            (define-key map (kbd "C-c $") #'loophole-bind-kmacro)
            map)
  (if loophole-mode
      (push 'loophole-map-alist emulation-mode-map-alists)
    (setq emulation-mode-map-alists
          (delq 'loophole-map-alist emulation-mode-map-alists))
    (loophole-stop-edit)))

(defun loophole-mode-set-lighter-format (style &optional format)
  "Set lighter format for loophole mode.
STYLE is a symbol to specify style of format.
STYLE can be 'number', 'tag', 'simple', 'static', 'custom',
and any other Lisp object.  Each means as follows.
number: display lighter-base suffixed with editing status,
        and number of enabled keymaps.  If no keymaps are
        enabled, numeric suffix is omitted.
tag:    display lighter-base suffixed with editing status,
        and concatenated tag strings of keymaps.  If no
        keymaps are enabled, tag suffix is omitted.
simple: display lighter-base suffixed with editing status
static: display lighter-base with no suffix.
custom: use FORMAT.
If STYLE is other than above, lighter is omitted."
  (let ((form (cond
               ((eq style 'number)
                '(""
                  loophole-mode-lighter-base
                  (loophole-map-editing loophole-mode-lighter-editing-sign)
                  (:eval (let ((n (length
                                   (delq nil
                                         (mapcar
                                          (lambda (e) (symbol-value (car e)))
                                          loophole-map-alist)))))
                           (if (zerop n)
                               ""
                             (format ":%d" n))))))
               ((eq style 'tag)
                '(""
                  loophole-mode-lighter-base
                  (loophole-map-editing
                   (""
                    loophole-mode-lighter-editing-sign
                    (:eval (let ((s (caar loophole-map-alist)))
                             (or (symbol-value s)
                                 (get (get s :loophole-map-variable)
                                      :loophole-tag))))))
                  (:eval (let ((l (delq nil
                                        (mapcar
                                         (lambda (e)
                                           (if (symbol-value (car e))
                                               (get (get (car e)
                                                         :loophole-map-variable)
                                                    :loophole-tag)))
                                         loophole-map-alist))))
                           (if (zerop (length l))
                               ""
                             (concat "#" (mapconcat 'identity l ",")))))))
               ((eq style 'simple)
                '(""
                  loophole-mode-lighter-base
                  (loophole-map-editing loophole-mode-lighter-editing-sign)))
               ((eq style 'static) loophole-mode-lighter-base)
               ((eq style 'custom) format)
               (t "")))
        (cell (assq 'loophole-mode minor-mode-alist)))
    (if cell (setcdr cell (list form)))))

(provide 'loophole)

;;; loophole.el ends here

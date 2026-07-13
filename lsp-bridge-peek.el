;;; lsp-bridge-peek.el --- Show peek windows for lsp-bridge  -*- lexical-binding: t -*-

;; Filename: lsp-bridge-peek.el
;; Description: Show definitions and references in peek window
;; Author: AllTheLife <xjn208930@gmail.com>
;; Maintainer: AllTheLife <xjn208930@gmail.com>
;; Copyright (C) 2023, AllTheLife
;; Created: 2023-7-1 19:28 +0800
;; Version: 0.1
;; Last-Updated: 2023-7-15 20:23:54 +0800
;;           By: AllTheLife
;; URL: https://github.com/manateelazycat/lsp-bridge
;; Keywords:
;; Compatibility: emacs-version >= 28
;; Package-Requires: ((emacs "28"))
;;
;; Features that might be required by this library:
;;
;; Please check README
;;

;;; This file is NOT part of GNU Emacs

;;; License
;;
;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 51 Franklin Street, Fifth
;; Floor, Boston, MA 02110-1301, USA.

;;; Commentary:
;;
;;
;;

;;; Installation:
;;
;;
;;

;;; Customize:
;;
;;
;;
;; All of the above can customize by:
;;      M-x customize-group RET lsp-bridge-peek RET
;;

;;; Change log:
;;
;;

;;; Acknowledgements:
;;
;;
;;

;;; TODO
;;
;;
;;

;;; Require:

(require 'color)

;;; Code:

(defgroup lsp-bridge-peek nil
  "Perfect code reading experience in `lsp-bridge' with peek feature."
  :group 'lsp-bridge)

(defvar lsp-bridge-peek--ov nil
  "Overlay used to display the `lsp-bridge-peek' UI.")

(defvar lsp-bridge-peek--bg nil
  "Background color used for file contents when peeking.")

(defvar lsp-bridge-peek--bg-alt nil
  "Background color for unselected tags when peeking.")

(defvar lsp-bridge-peek--bg-selected nil
  "Background color for selected tags when peeking.")

(defvar lsp-bridge-peek--method-fg nil
  "Foreground color for methods when peeking.")

(defvar lsp-bridge-peek--path-fg nil
  "Foreground color for file paths when peeking.")

(defvar lsp-bridge-peek--pos-fg nil
  "Foreground color for postions when peeking.")

(defvar lsp-bridge-peek--symbol-selected nil
  "Foreground color for symbols are selected when peeking.")

(defvar lsp-bridge-peek--symbol-alt nil
  "Foreground color for alt symbols when peeking.")

(defvar lsp-bridge-peek--ace-seqs nil
  "Ace key sequences for ace jump.")

(defvar lsp-bridge-peek--symbol-bounds nil
  "Symbol bounds for ace jump.
Its car is the bound offset, i.e., the starting point of the
region to perform ace jump on.  Its cdr is a list of the symbol
bounds as returned by `lsp-bridge--search-symbols'.")

(defvar lsp-bridge-peek--content-update nil
  "Non-nil means the content in the peek window is updated.")

(defvar lsp-bridge-peek--temp-buffer-alist nil
  "Temporary buffers created for files that weren't already visited.
The buffers will be
killed after disabling `lsp-bridge-peek--mode'.")

(defvar lsp-bridge-peek--buffer-alist nil
  "Map file paths to buffers used to render their peek contents.")

(defvar lsp-bridge-peek-chosen-displaying-list '(nil nil nil)
  "Information saved to display the definition or reference.
The first item in the list is the first definition or reference displayed,
the second item is the definition or reference that will be selected, and
the third item is the last definition or reference displayed.")

(defvar lsp-bridge-peek-file-and-pos-before-jump nil)

(defvar lsp-bridge-peek-symbol-tree nil
  "A tree structure for storing symbols, each element is a list. The first
item of the list is the name of the symbol, the second item stores the paths
to files where definitions and references are, the third item stores the
positions where definitions and references are in the file, the fourth item
is the index of the parent node of the symbol in the list, and the fifth
item is a list, storing the index of the node's child nodes in the list.
The sixth item stores which child node is selected next. The seventh item
stores how many lines the file content was moved.")

(defvar lsp-bridge-peek-symbol-at-point nil
  "A variable that stores the current symbol to be added.")

(defvar lsp-bridge-peek-selected-symbol nil
  "A variable that stores which symbol is currently selected.")

(defvar lsp-bridge-peek-ace-list nil
  "A list that stores the related information used to recovery the status before ace peek.
The first is the buffer which need killing. The second is the position before ace peek.
The third is the buffer before ace peek. The fourth is the buffer where the symbol is.
The fifth is the position where the symbol is.")

(defvar lsp-bridge-peek--request-counter 0
  "Monotonic counter used to identify asynchronous peek requests.")

(defvar lsp-bridge-peek--active-request nil
  "Plist describing the active asynchronous peek request.")

(defun lsp-bridge-peek--next-request-id ()
  "Return a new peek request identifier."
  (setq lsp-bridge-peek--request-counter
        (1+ lsp-bridge-peek--request-counter)))

(defun lsp-bridge-peek--request-active-p (session-id)
  "Return non-nil when SESSION-ID is the active peek request."
  (equal session-id (plist-get lsp-bridge-peek--active-request :id)))

(defun lsp-bridge-peek--arm-request-timeout (session-id stage)
  "Start or reset the timeout for SESSION-ID at STAGE."
  (when (lsp-bridge-peek--request-active-p session-id)
    (when-let* ((timer (plist-get lsp-bridge-peek--active-request :timer)))
      (cancel-timer timer))
    (setq lsp-bridge-peek--active-request
          (plist-put
           lsp-bridge-peek--active-request :timer
           (run-at-time lsp-bridge-peek-request-timeout nil
                        #'lsp-bridge-peek--request-failed
                        nil session-id (concat stage " timeout"))))))

(defun lsp-bridge-peek--cleanup-request (&optional session-id)
  "Clean up the active request when it matches SESSION-ID.
When SESSION-ID is nil, clean up unconditionally."
  (when (and lsp-bridge-peek--active-request
             (or (null session-id)
                 (lsp-bridge-peek--request-active-p session-id)))
    (let ((temp-buffer (plist-get lsp-bridge-peek--active-request
                                  :temporary-buffer)))
      (when-let* ((timer (plist-get lsp-bridge-peek--active-request :timer)))
        (cancel-timer timer))
      (dolist (key '(:origin-marker :target-marker))
        (when-let* ((marker (plist-get lsp-bridge-peek--active-request key)))
          (set-marker marker nil)))
      (when (buffer-live-p temp-buffer)
        (kill-buffer temp-buffer)))
    (setq lsp-bridge-peek--active-request nil
          lsp-bridge-peek-symbol-at-point nil
          lsp-bridge-peek-ace-list nil)))

(defun lsp-bridge-peek--request-failed (_position session-id stage)
  "Finish SESSION-ID after an unsuccessful STAGE request."
  (when (lsp-bridge-peek--request-active-p session-id)
    (lsp-bridge-peek--cleanup-request session-id)
    (message "[LSP-Bridge] Peek %s not found." stage)))

(defface lsp-bridge-peek--highlight-symbol-face
  `((t :foreground "white" :background "#623d73"))
  "Face for highlighting the symbol you want to look through."
  :group 'lsp-bridge-peek)

(defface lsp-bridge-peek-border-face
  `((t :height 15 :background ,(face-attribute 'default :foreground) :extend t))
  "Face used for borders of peek windows.
You can customize the appearance of the borders by setting the
height and background properties of the face."
  :group 'lsp-bridge-peek)

(defface lsp-bridge-peek-ace-str-face
  '((((background light))
     :foreground "#dddddd" :background "#666666")
    (t
     :foreground "#222222" :background "#c0c0c0"))
  "Face used for ace strings."
  :group 'lsp-bridge-peek)

(defcustom lsp-bridge-peek-file-content-height 12
  "Number of lines displaying file contents in the peek window."
  :type 'integer
  :group 'lsp-bridge-peek)


(defcustom lsp-bridge-peek-file-content-scroll-margin 1
  "Set how much lsp-bridge-peek-file-content-next-line/-prev-line should scroll up and down."
  :type 'integer
  :group 'lsp-bridge-peek)

(defcustom lsp-bridge-peek-list-height 3
  "Number of definitions/references displayed in the peek window."
  :type 'integer
  :group 'lsp-bridge-peek)

(defcustom lsp-bridge-peek-request-timeout 10
  "Seconds to wait for each asynchronous peek response."
  :type 'number
  :group 'lsp-bridge-peek)

(defcustom lsp-bridge-peek-ace-keys '(?a ?s ?d ?f ?j ?k ?l ?\;)
  "Ace keys used for `lsp-bridge-peek-through'."
  :type '(repeat :tag "Keys" character)
  :group 'lsp-bridge-peek)

(defcustom lsp-bridge-peek-ace-cancel-keys '(?\C-g ?q)
  "Keys used for cancel an ace session."
  :type '(repeat :tag "Keys" character)
  :group 'lsp-bridge-peek)

(defcustom lsp-bridge-peek-keymap
  (let ((map (make-sparse-keymap)))
    ;; Browse file
    (define-key map (kbd "M-n") 'lsp-bridge-peek-file-content-next-line)
    (define-key map (kbd "M-p") 'lsp-bridge-peek-file-content-prev-line)

    (define-key map (kbd "n") 'lsp-bridge-peek-file-content-next-line)
    (define-key map (kbd "p") 'lsp-bridge-peek-file-content-prev-line)

    ;; Browse in the definition/reference list
    (define-key map (kbd "M-N") 'lsp-bridge-peek-list-next-line)
    (define-key map (kbd "M-P") 'lsp-bridge-peek-list-prev-line)

    (define-key map (kbd "N") 'lsp-bridge-peek-list-next-line)
    (define-key map (kbd "P") 'lsp-bridge-peek-list-prev-line)

    ;; Browse in the tree history
    (define-key map (kbd "<right>") 'lsp-bridge-peek-tree-next-node)
    (define-key map (kbd "<left>") 'lsp-bridge-peek-tree-previous-node)
    (define-key map (kbd "<up>") 'lsp-bridge-peek-tree-previous-branch)
    (define-key map (kbd "<down>") 'lsp-bridge-peek-tree-next-branch)

    (define-key map (kbd "l") 'lsp-bridge-peek-tree-next-node)
    (define-key map (kbd "h") 'lsp-bridge-peek-tree-previous-node)
    (define-key map (kbd "k") 'lsp-bridge-peek-tree-previous-branch)
    (define-key map (kbd "j") 'lsp-bridge-peek-tree-next-branch)

    ;; Peek through
    (define-key map (kbd "t") 'lsp-bridge-peek-through)

    ;; Jump
    (define-key map (kbd "M-l j") 'lsp-bridge-peek-jump)
    (define-key map (kbd "M-l b") 'lsp-bridge-peek-jump-back)

    (define-key map (kbd "8") 'lsp-bridge-peek-jump)
    (define-key map (kbd "7") 'lsp-bridge-peek-jump-back)

    ;; Abort
    (define-key map [remap keyboard-quit] 'lsp-bridge-peek-abort)
    map)
  "Keymap used for `lsp-bridge-peek' sessions."
  :type 'keymap
  :group 'lsp-bridge-peek)

(define-minor-mode lsp-bridge-peek-mode
  "Mode for `lsp-bridge-peek'.
This mode is created merely fo handling the UI (display, keymap,
etc.), and is not for interactive use. Users should use commands
like `lsp-bridge-peek', `lsp-bridge-peek-abort', `lsp-bridge-peek-restore',
which take care of setting up other things."
  :keymap lsp-bridge-peek-keymap
  (cond
   (lsp-bridge-peek-mode
    (when lsp-bridge-peek--ov (delete-overlay lsp-bridge-peek--ov))
    (setq lsp-bridge-peek--ov
	      (let ((ov-pos (line-end-position)))
	        (make-overlay ov-pos ov-pos)))
    (let ((origin-window
           (plist-get lsp-bridge-peek--active-request :origin-window)))
      (overlay-put
       lsp-bridge-peek--ov 'window
       (if lsp-bridge-peek--active-request
           (and (window-live-p origin-window)
                (eq (window-buffer origin-window) (current-buffer))
                origin-window)
         (selected-window))))
    (let* ((bg-mode (frame-parameter nil 'background-mode))
	       (bg-unspecified-p (string= (face-background 'default)
                                      "unspecified-bg"))
	       (bg (cond
		        ((and bg-unspecified-p (eq bg-mode 'dark)) "#333333")
		        ((and bg-unspecified-p (eq bg-mode 'light)) "#dddddd")
		        (t (face-background 'default)))))
      (cond
       ((eq bg-mode 'dark)
	    (setq lsp-bridge-peek--bg (lsp-bridge--color-blend "#ffffff" bg 0.03)
	          lsp-bridge-peek--bg-alt (lsp-bridge--color-blend "#ffffff" bg 0.2)
	          lsp-bridge-peek--bg-selected (lsp-bridge--color-blend "#ffffff" bg 0.4)
	          lsp-bridge-peek--method-fg "gray"
	          lsp-bridge-peek--path-fg "#6aaf50"
	          lsp-bridge-peek--pos-fg "#f57e00"
	          lsp-bridge-peek--symbol-selected "orange"
	          lsp-bridge-peek--symbol-alt "#dedede"))
       (t
	    (setq lsp-bridge-peek--bg (lsp-bridge--color-blend "#000000" bg 0.02)
	          lsp-bridge-peek--bg-alt (lsp-bridge--color-blend "#000000" bg 0.12)
	          lsp-bridge-peek--bg-selected (lsp-bridge--color-blend "#000000" bg 0.06)
	          lsp-bridge-peek--method-fg "dark"
	          lsp-bridge-peek--path-fg "#477a33"
	          lsp-bridge-peek--pos-fg "#b06515"
	          lsp-bridge-peek--symbol-selected "#ff6200"
	          lsp-bridge-peek--symbol-alt "#212121"))))
    (setq lsp-bridge-peek--content-update t)
    (setq lsp-bridge-peek-chosen-displaying-list (make-list 3 0))
    (setf (nth 2 lsp-bridge-peek-chosen-displaying-list) (1- lsp-bridge-peek-list-height))
    (add-hook 'post-command-hook #'lsp-bridge-peek--show nil 'local))
   (t
    (lsp-bridge-peek--cleanup-request)
    (when lsp-bridge-peek--ov (delete-overlay lsp-bridge-peek--ov))
    (mapc (lambda (pair)
	        (kill-buffer pair))
	      lsp-bridge-peek--temp-buffer-alist)
    (setq lsp-bridge-peek--temp-buffer-alist nil
	      lsp-bridge-peek--buffer-alist nil
	      lsp-bridge-peek--ov nil
	      lsp-bridge-peek--bg nil
	      lsp-bridge-peek--bg-alt nil
	      lsp-bridge-peek--bg-selected nil
	      lsp-bridge-peek--method-fg nil
	      lsp-bridge-peek--path-fg nil
	      lsp-bridge-peek--pos-fg nil
	      lsp-bridge-peek--symbol-selected nil
	      lsp-bridge-peek--symbol-alt nil
	      lsp-bridge-peek-ace-list nil
	      lsp-bridge-peek-symbol-tree nil
	      lsp-bridge-peek-selected-symbol nil
	      lsp-bridge-peek-chosen-displaying-list (make-list 3 nil)
	      lsp-bridge-peek-file-and-pos-before-jump nil
	      lsp-bridge-peek--ace-seqs nil
	      lsp-bridge-peek--symbol-bounds nil)
    (remove-hook 'post-command-hook #'lsp-bridge-peek--show 'local))))

;; Ref: https://www.w3.org/TR/WCAG20/#relativeluminancedef
(defun lsp-bridge--color-srgb-to-rgb (c)
  "Convert an sRGB component C to an RGB one."
  (if (<= c 0.03928)
      (/ c 12.92)
    (expt (/ (+ c 0.055) 1.055) 2.4)))

(defun lsp-bridge--color-rgb-to-srgb (c)
  "Convert an RGB component C to an sRGB one."
  (if (<= c (/ 0.03928 12.92))
      (* c 12.92)
    (- (* 1.055 (expt c (/ 1 2.4))) 0.055)))

(defun lsp-bridge--color-blend (c1 c2 alpha)
  "Blend two colors C1 and C2 with ALPHA.
C1 and C2 are hexadecimal strings.  ALPHA is a number between 0.0
and 1.0 which is the influence of C1 on the result.

The blending is done in the sRGB space, which should make ALPHA
feels more linear to human eyes."
  (pcase-let ((`(,r1 ,g1 ,b1)
               (mapcar #'lsp-bridge--color-rgb-to-srgb
                       (color-name-to-rgb c1)))
              (`(,r2 ,g2 ,b2)
               (mapcar #'lsp-bridge--color-rgb-to-srgb
                       (color-name-to-rgb c2)))
              (blend-and-to-rgb
               (lambda (x y)
                 (lsp-bridge--color-srgb-to-rgb
                  (+ (* alpha x)
                     (* (- 1 alpha) y))))))
    (color-rgb-to-hex
     (funcall blend-and-to-rgb r1 r2)
     (funcall blend-and-to-rgb g1 g2)
     (funcall blend-and-to-rgb b1 b2)
     2)))

(defun lsp-bridge--add-face (str face)
  "Add FACE to STR, and return it.
This is mainly for displaying STR in an overlay.  For example, if
FACE specifies background color, then STR will have that
background color, with all other face attributes preserved.

`default' face is appended to make sure the display in overlay is
not affected by its surroundings."
  (let ((len (length str)))
    (add-face-text-property 0 len face nil str)
    (add-face-text-property 0 len 'default 'append str)
    str))

(defun lsp-bridge-peek-abort ()
  "Abort peeking."
  (interactive)
  (lsp-bridge-peek-mode -1))

(defun lsp-bridge-peek--make-border ()
  "Return the border to be used in peek windows."
  (propertize "\n"
	          'face 'lsp-bridge-peek-border-face))

(defun lsp-bridge-peek--position-to-point (position)
  "Convert UTF-16 LSP POSITION to an Emacs buffer position."
  (save-excursion
    ;; Let the shared converter determine the start of the LSP line.  In
    ;; particular, Org Babel positions are relative to the source block.
    (goto-char (acm-backend-lsp-position-to-point
                (list :line (plist-get position :line) :character 0)))
    (let ((units (plist-get position :character)))
      (while (and (> units 0) (not (eolp)))
        (let ((width (if (> (char-after) #xffff) 2 1)))
          (if (< units width)
              (setq units 0)
            (forward-char 1)
            (setq units (- units width))))))
    (point)))

(defun lsp-bridge-peek--get-content (pos content-move)
  (setq file-content nil)
  (goto-char (lsp-bridge-peek--position-to-point pos))
  (let* ((beg (save-excursion
		        (forward-line content-move)
		        (line-beginning-position)))
	     (end (save-excursion
		        (forward-line content-move)
		        (forward-line (1- lsp-bridge-peek-file-content-height))
		        (line-end-position)))
	     (highlight-begin (point))
	     (highlight-end (save-excursion
			              (forward-symbol 1)
			              (point))))
    (font-lock-fontify-region beg end)
    (put-text-property highlight-begin highlight-end 'face 'lsp-bridge-peek--highlight-symbol-face)
    (setq file-content (concat (buffer-substring beg end) "\n"))
    (remove-text-properties highlight-begin highlight-end 'face))
  file-content)

(defun lsp-bridge-peek--find-file-buffer (file)
  "Return a buffer containing FILE for rendering and ace selection."
  (or (find-buffer-visiting file)
      (let ((buffer (alist-get file lsp-bridge-peek--buffer-alist
                               nil nil #'equal)))
        (and (buffer-live-p buffer) buffer))
      (let ((buffer (generate-new-buffer
                     (format " *lsp-bridge-peek-%s*" file))))
        (with-current-buffer buffer
          (insert-file-contents file)
          (let ((buffer-file-name file))
            (delay-mode-hooks (set-auto-mode))))
        (push (cons file buffer) lsp-bridge-peek--buffer-alist)
        (push buffer lsp-bridge-peek--temp-buffer-alist)
        buffer)))

(defun lsp-bridge--attach-ace-str (str sym-bounds bound-offset ace-seqs)
  "Return a copy of STR with ace strings attached.
SYM-BOUNDS specifies the symbols in STR, as returned by
`lsp-bridge-peek--search-symbols'.  BOUND-OFFSET is the starting point of
STR in the buffer.  ACE-SEQS is the ace key sequences, as
returned by `lsp-bridge-peek--ace-key-seqs' or `lsp-bridge-peek--pop-ace-key-seqs'.
The beginnings of each symbol are replaced by ace strings with
`lsp-bridge-peek-ace-string-face' attached."
  (let* ((nsyms (length sym-bounds))
         (new-str (string-to-multibyte (copy-sequence str))))
    (dotimes (n nsyms)
      (when-let* ((ace-seq (nth n ace-seqs))
                  (bounds (nth n sym-bounds))
                  (beg (- (car bounds) bound-offset))
                  (end (- (cdr bounds) bound-offset))
                  ((<= 0 beg))
                  ((< beg end))
                  ((< beg (length new-str))))
        (let ((ace-str-len (min (length ace-seq)
                                (- end beg)
                                (- (length new-str) beg))))
          (dotimes (idx ace-str-len)
            (let ((pos (+ beg idx)))
              (setq new-str
                    (concat (substring new-str 0 pos)
                            (char-to-string (nth idx ace-seq))
                            (substring new-str (1+ pos))))))
          (put-text-property beg (+ beg ace-str-len)
                             'face 'lsp-bridge-peek-ace-str-face new-str))))
    new-str))

(defun lsp-bridge-peek--file-content ()
  "Return a string for displaying file content."
  (let* ((n (nth 1 lsp-bridge-peek-chosen-displaying-list))
	     (selected-symbol (nth lsp-bridge-peek-selected-symbol lsp-bridge-peek-symbol-tree))
	     (path-list (nth 1 selected-symbol))
	     (pos-list (nth 2 selected-symbol))
	     (content-move-list (nth 6 selected-symbol))
	     (file (nth n path-list))
	     (pos (nth n pos-list))
	     (content-move (nth n content-move-list))
	     (buffer (lsp-bridge-peek--find-file-buffer file))
	     (file-content nil))
    (with-current-buffer buffer
      (save-excursion
        (setq file-content (lsp-bridge-peek--get-content pos content-move))))
    (when (and lsp-bridge-peek--symbol-bounds lsp-bridge-peek--ace-seqs)
      (setq file-content
	        (lsp-bridge--attach-ace-str file-content
					                    (cdr lsp-bridge-peek--symbol-bounds)
					                    (car lsp-bridge-peek--symbol-bounds)
					                    lsp-bridge-peek--ace-seqs)))
    file-content))

(defun lsp-bridge-peek--displaying-list ()
  "Return a string for displayed definition/reference list."
  (let* ((selected-symbol (nth lsp-bridge-peek-selected-symbol lsp-bridge-peek-symbol-tree))
	     (path-list (nth 1 selected-symbol))
	     (pos-list (nth 2 selected-symbol))
	     (total-n (min lsp-bridge-peek-list-height (length path-list)))
	     (first-displayed-id (nth 0 lsp-bridge-peek-chosen-displaying-list))
	     (selected-id (nth 1 lsp-bridge-peek-chosen-displaying-list))
	     (last-displayed-id (nth 2 lsp-bridge-peek-chosen-displaying-list))
	     (displaying-list (make-list total-n nil)))
    (dotimes (n total-n)
      (let* ((filename (nth (+ first-displayed-id n) path-list))
	         (pos (nth (+ first-displayed-id n) pos-list))
	         (line (number-to-string (1+ (plist-get pos :line))))
	         (char (number-to-string (1+ (plist-get pos :character))))
	         (method (if (= (+ first-displayed-id n) 0) "definition" "reference"))
	         (bg-selected (list :background lsp-bridge-peek--bg-selected :extend t))
	         (bg-alt (list :background lsp-bridge-peek--bg-alt :extend t)))
	    (lsp-bridge--add-face method (list :foreground  lsp-bridge-peek--method-fg
					                       :extend t))
	    (lsp-bridge--add-face filename (list :foreground lsp-bridge-peek--path-fg
					                         :extend t))
	    (lsp-bridge--add-face line (list :foreground lsp-bridge-peek--pos-fg
					                     :extend t))
	    (lsp-bridge--add-face char (list :foreground lsp-bridge-peek--pos-fg
					                     :extend t))
	    (if (= (+ first-displayed-id n) selected-id)
	        (setf (nth n displaying-list)
		          (lsp-bridge--add-face
		           (concat "(" method ") " filename " " line ":" char "\n")
		           bg-selected))
	      (setf (nth n displaying-list)
		        (lsp-bridge--add-face
		         (concat "(" method ") " filename " " line ":" char "\n")
		         bg-alt)))))
    (string-join displaying-list)))

(defun lsp-bridge-peek--tree-history ()
  "Return a string for displaying the tree history of symbols were peeked."
  (let* ((selected-symbol (nth lsp-bridge-peek-selected-symbol lsp-bridge-peek-symbol-tree))
	     (total-n (length (nth 1 selected-symbol)))
	     (selected-id (nth 1 lsp-bridge-peek-chosen-displaying-list))
	     (history-string (format "[%s]" (lsp-bridge--add-face
					                     (format "%s" (nth 0 selected-symbol))
					                     (list :foreground lsp-bridge-peek--symbol-selected :extend t)))))
    (while (nth 3 selected-symbol)
      (setq selected-symbol (nth (nth 3 selected-symbol) lsp-bridge-peek-symbol-tree))
      (setq history-string (concat (format "%s %s " (lsp-bridge--add-face
						                             (format "%s" (nth 0 selected-symbol))
						                             (list :foreground lsp-bridge-peek--symbol-alt
							                               :extend t))
					                       (if (> (length (nth 4 selected-symbol)) 1)
					                           "<" "->"))
				                   history-string)))
    (setq selected-symbol (nth lsp-bridge-peek-selected-symbol lsp-bridge-peek-symbol-tree))
    (while (nth 4 selected-symbol)
      (setq child-list (nth 4 selected-symbol))
      (setq selected-symbol (nth
			                 (nth
			                  (nth 5 selected-symbol)
			                  (nth 4 selected-symbol))
			                 lsp-bridge-peek-symbol-tree))
      (setq history-string (concat history-string
				                   (format " %s %s"
					                       (if (> (length child-list) 1)
					                           "<" "->")
					                       (lsp-bridge--add-face
					                        (format "%s" (nth 0 selected-symbol))
					                        (list :foreground lsp-bridge-peek--symbol-alt :extend t))))))
    (setq history-string (concat
			              (format "(%s/%s) " (1+ selected-id) total-n)
			              history-string "\n"))
    (lsp-bridge--add-face history-string (list :background lsp-bridge-peek--bg-alt
					                           :extend t))
    history-string))

(defun lsp-bridge-peek-define--return (filename filehost position session-id)
  "Handle a definition response belonging to SESSION-ID."
  (when (lsp-bridge-peek--request-active-p session-id)
    (setq filename (concat (cdr (assoc filehost lsp-bridge-tramp-alias-alist))
                           filename))
    (push filename (nth 1 lsp-bridge-peek-symbol-at-point))
    (push position (nth 2 lsp-bridge-peek-symbol-at-point))
    (push 0 (nth 6 lsp-bridge-peek-symbol-at-point))
    (let ((target-buffer (plist-get lsp-bridge-peek--active-request
                                    :target-buffer))
          (target-marker (plist-get lsp-bridge-peek--active-request
                                    :target-marker)))
      (if (and (buffer-live-p target-buffer)
               target-marker
               (marker-position target-marker))
          (with-current-buffer target-buffer
            (save-excursion
              (goto-char target-marker)
              (lsp-bridge-peek--arm-request-timeout session-id "references")
              (unless (lsp-bridge-call-file-api
                       "peek_find_references"
                       (lsp-bridge--position) position session-id filename)
                (lsp-bridge-peek--request-failed
                 nil session-id "references"))))
        (lsp-bridge-peek--request-failed nil session-id "target buffer")))))

(defun lsp-bridge-peek-references--return
    (references-content references-counter session-id)
  "Handle references for SESSION-ID and update its peek tree."
  (when (lsp-bridge-peek--request-active-p session-id)
    (when references-content
      (with-temp-buffer
        (insert references-content)
        (goto-char (point-min))
        (dotimes (_ references-counter)
          (let ((line (buffer-substring (point) (line-end-position))))
            (forward-line 1)
            (let ((character (buffer-substring (point) (line-end-position))))
              (forward-line 1)
              (let ((filename (buffer-substring (point) (line-end-position))))
                (forward-line 1)
                (push filename (nth 1 lsp-bridge-peek-symbol-at-point))
                (push (list :line (string-to-number line)
                            :character (string-to-number character))
                      (nth 2 lsp-bridge-peek-symbol-at-point))
                (push (- (/ lsp-bridge-peek-file-content-height 2))
                      (nth 6 lsp-bridge-peek-symbol-at-point)))))))
      (setf (nth 1 lsp-bridge-peek-symbol-at-point)
            (nreverse (nth 1 lsp-bridge-peek-symbol-at-point))
            (nth 2 lsp-bridge-peek-symbol-at-point)
            (nreverse (nth 2 lsp-bridge-peek-symbol-at-point))
            (nth 6 lsp-bridge-peek-symbol-at-point)
            (nreverse (nth 6 lsp-bridge-peek-symbol-at-point))))
    (let ((origin-buffer (plist-get lsp-bridge-peek--active-request
                                    :origin-buffer))
          (origin-marker (plist-get lsp-bridge-peek--active-request
                                    :origin-marker)))
      (if (and (buffer-live-p origin-buffer)
               origin-marker
               (marker-position origin-marker))
          (with-current-buffer origin-buffer
            (save-excursion
              (goto-char origin-marker)
              (when lsp-bridge-peek-selected-symbol
                (push (length lsp-bridge-peek-symbol-tree)
                      (nth 4 (nth lsp-bridge-peek-selected-symbol
                                  lsp-bridge-peek-symbol-tree)))
                (unless (nth 5 (nth lsp-bridge-peek-selected-symbol
                                    lsp-bridge-peek-symbol-tree))
                  (setf (nth 5 (nth lsp-bridge-peek-selected-symbol
                                      lsp-bridge-peek-symbol-tree)) 0)))
              (setf (nth 3 lsp-bridge-peek-symbol-at-point)
                    lsp-bridge-peek-selected-symbol
                    (nth 5 lsp-bridge-peek-symbol-at-point) 0)
              (setq lsp-bridge-peek-selected-symbol
                    (length lsp-bridge-peek-symbol-tree))
              (setq lsp-bridge-peek-symbol-tree
                    (append lsp-bridge-peek-symbol-tree
                            (list lsp-bridge-peek-symbol-at-point)))
              (setq lsp-bridge-peek-symbol-at-point nil)
              (if lsp-bridge-peek-mode
                  (lsp-bridge-peek--show 'force)
                (lsp-bridge-peek-mode 1)
                (lsp-bridge-peek--show))))
        (message "[LSP-Bridge] Peek origin buffer no longer exists.")))
    (lsp-bridge-peek--cleanup-request session-id)))

(defun lsp-bridge-peek--show (&optional force)
  "Show the peek window or deal with the update of contents in peek windows.
When FORCE if non-nil, the content of the peek window is recalculated."
  (unless (minibufferp)
    (let ((overlay-pos (min (point-max) (1+ (line-end-position)))))
      (move-overlay lsp-bridge-peek--ov overlay-pos overlay-pos))
    (when (or lsp-bridge-peek--content-update force)
      (let* ((initial-newline (if (eq (line-end-position) (point-max)) "\n" ""))
	         (border (lsp-bridge-peek--make-border)))
	    (overlay-put lsp-bridge-peek--ov 'after-string
		             (concat initial-newline
			                 border
			                 (concat
			                  (lsp-bridge-peek--file-content)
			                  (lsp-bridge-peek--displaying-list)
			                  (lsp-bridge-peek--tree-history))
			                 border)))
      (setq lsp-bridge-peek--content-update nil))))

(defun lsp-bridge-peek (&optional session-id)
  "Peek the definition of the symbol at point.
SESSION-ID is supplied internally by `lsp-bridge-peek-through'."
  (interactive)
  (unless session-id
    (when lsp-bridge-peek--active-request
      (user-error "A previous LSP peek request is still pending"))
    (setq session-id (lsp-bridge-peek--next-request-id))
    (setq lsp-bridge-peek--active-request
          (list :id session-id
                :origin-buffer (current-buffer)
                :origin-marker (point-marker)
                :origin-window (selected-window)
                :target-buffer (current-buffer)
                :target-marker (point-marker)))
    (lsp-bridge-peek--arm-request-timeout session-id "definition"))
  (setq lsp-bridge-peek-symbol-at-point (make-list 7 nil))
  (setf (nth 0 lsp-bridge-peek-symbol-at-point) (symbol-at-point))
  (unless (and (nth 0 lsp-bridge-peek-symbol-at-point)
               (lsp-bridge-call-file-api
                "peek_find_definition" (lsp-bridge--position) session-id))
    (lsp-bridge-peek--request-failed nil session-id "definition")))

(defun lsp-bridge-peek--error-if-not-peeking ()
  "Throw an error if not in a peek session."
  (unless lsp-bridge-peek-mode
    (user-error "Not in a peek session.")))

(defun lsp-bridge-peek-list-move-line (num)
  (lsp-bridge-peek--error-if-not-peeking)
  (cl-symbol-macrolet ((first-displayed-id (nth 0 lsp-bridge-peek-chosen-displaying-list))
		               (selected-id (nth 1 lsp-bridge-peek-chosen-displaying-list))
		               (last-displayed-id (nth 2 lsp-bridge-peek-chosen-displaying-list))
		               (next (> num 0)))
    (unless (or (and
		         (= selected-id (1- (length (nth 1 (nth lsp-bridge-peek-selected-symbol
							                            lsp-bridge-peek-symbol-tree)))))
		         next)
		        (and (= selected-id 0) (not next)))
      (if (or (and (= selected-id last-displayed-id) next)
	          (and (= selected-id first-displayed-id) (not next)))
	      (progn
	        (setf first-displayed-id
		          (+ num first-displayed-id))
	        (setf last-displayed-id
		          (+ num last-displayed-id))))
      (setf selected-id (+ selected-id num))))
  (setq lsp-bridge-peek--content-update t))

(defun lsp-bridge-peek-list-next-line ()
  "Choose the next definition/reference in the list."
  (interactive)
  (lsp-bridge-peek-list-move-line 1))

(defun lsp-bridge-peek-list-prev-line ()
  "Choose the prev definition/reference in the list."
  (interactive)
  (lsp-bridge-peek-list-move-line -1))

(defun lsp-bridge-peek-file-content-move (num)
  (lsp-bridge-peek--error-if-not-peeking)
  (cl-symbol-macrolet ((selected-id (nth 1 lsp-bridge-peek-chosen-displaying-list))
		               (selected-symbol (nth lsp-bridge-peek-selected-symbol lsp-bridge-peek-symbol-tree))
		               (content-move-list (nth 6 selected-symbol))
		               (content-move (nth selected-id content-move-list)))
    (setf content-move (+ content-move num))
    (setq lsp-bridge-peek--content-update t)))

(defun lsp-bridge-peek-file-content-next-line ()
  "Step through the next line of file content."
  (interactive)
  (lsp-bridge-peek-file-content-move lsp-bridge-peek-file-content-scroll-margin))

(defun lsp-bridge-peek-file-content-prev-line ()
  "Step through the next line of file content."
  (interactive)
  (lsp-bridge-peek-file-content-move (* lsp-bridge-peek-file-content-scroll-margin -1)))

(defun lsp-bridge-peek-jump ()
  "Jump to where the definition/reference is."
  (interactive)
  (lsp-bridge-peek--error-if-not-peeking)
  (setq lsp-bridge-peek-file-and-pos-before-jump (list))
  (push (point) lsp-bridge-peek-file-and-pos-before-jump)
  (push (buffer-file-name) lsp-bridge-peek-file-and-pos-before-jump)
  (let* ((selected-id (nth 1 lsp-bridge-peek-chosen-displaying-list))
	     (selected-symbol (nth lsp-bridge-peek-selected-symbol lsp-bridge-peek-symbol-tree))
	     (path-list (nth 1 selected-symbol))
	     (pos-list (nth 2 selected-symbol))
	     (file (nth selected-id path-list))
	     (pos (nth selected-id pos-list)))
    (lsp-bridge-jump-to-file file pos)
    ))

(defun lsp-bridge-peek-jump-back ()
  "Jump to the file and position before jump."
  (interactive)
  (when lsp-bridge-peek-file-and-pos-before-jump
    (lsp-bridge-jump-to-file
     (nth 0 lsp-bridge-peek-file-and-pos-before-jump)
     (nth 1 lsp-bridge-peek-file-and-pos-before-jump)
     )))

(defun lsp-bridge-peek--search-symbols (line)
  "Search for symbols from current position to LINEs after.
The search jumps over comments/strings.

The returned value is a list of cons pairs (START . END), the
start/end position of each symbol.  Point will not be moved."
  (let ((bound (save-excursion
		         (forward-line (1- line))
		         (line-end-position)))
	    (symbol-list))
    (save-excursion
      (cl-loop
       while
       (forward-symbol 1)
       do
       (when (> (point) bound)
	     (cl-return))
       (push (cons (save-excursion
		             (forward-symbol -1)
		             (point))
		           (point))
	         symbol-list)))
    (nreverse symbol-list)))

(defun lsp-bridge-peek--ace-key-seqs (n)
  "Make ace key sequences for N symbols.
N can be the length of the list returned by
`lsp-bridge-peek--search-symbols'.  The keys used are
`lsp-bridge-peek-ace-keys'."
  (unless (and (listp lsp-bridge-peek-ace-keys)
	           (null (cl-remove-if #'integerp lsp-bridge-peek-ace-keys))
	           (eq (cl-remove-duplicates lsp-bridge-peek-ace-keys)
		           lsp-bridge-peek-ace-keys))
    (user-error "Invalid `lsp-bridge-peek-ace-keys'"))
  (let* ((key-num (length lsp-bridge-peek-ace-keys))
	     (key-seq-length (pcase n
			               (0 0)
			               (1 1)
			               ;; Though `log' is a float-point operation, this is
                           ;; accurate for sym-num in a huge range.
			               (_ (ceiling (log n key-num)))))
	     (key-seq (make-list n nil))
	     nth-ace-key)
    (dotimes (nkey key-seq-length)
      (setq nth-ace-key -1)
      (dotimes (nsym n)
	    (when (eq (% nsym (expt key-num nkey)) 0)
	      (setq nth-ace-key (% (1+ nth-ace-key) key-num)))
	    (push (nth nth-ace-key lsp-bridge-peek-ace-keys) (nth nsym key-seq))))
    key-seq))

(defun lsp-bridge-peek--pop-ace-key-seqs (seqs char)
  "Modify ace key sequences SEQS as CHAR is pressed.
This sets elements in SEQS which not begin with CHAR to nil, and
pop the element which begin with CHAR.  When the only non-nil
element in seqs is poped, this returns its index, as the element
is hit by user input.

The modified SEQS is returned.  When CHAR is not the car of any
element in SEQS, this does nothing, and returns the original
list."
  (if (not (memq char (mapcar #'car seqs)))
      seqs
    (let (last-poped-idx)
      (dotimes (n (length seqs))
        (if (eq (car (nth n seqs)) char)
            (progn
              (pop (nth n seqs))
              (setq last-poped-idx n))
          (setf (nth n seqs) nil)))
      (if (null (cl-remove-if #'null seqs))
          last-poped-idx
        seqs))))

(defun lsp-bridge-ace-pick-point-in-peek-window ()
  "Pick a point in the buffer shown in peek window using \"ace\" operation.
The buffer and the point is returned in a cons cell."
  (let* ((selected-id (nth 1 lsp-bridge-peek-chosen-displaying-list))
	     (selected-symbol (nth lsp-bridge-peek-selected-symbol lsp-bridge-peek-symbol-tree))
	     (path-list (nth 1 selected-symbol))
	     (pos-list (nth 2 selected-symbol))
	     (content-move-list (nth 6 selected-symbol))
	     (file (nth selected-id path-list))
	     (buffer (lsp-bridge-peek--find-file-buffer file))
	     (pos (nth selected-id pos-list))
	     (content-move (nth selected-id content-move-list)))
    (setq lsp-bridge-peek--symbol-bounds
	      (with-current-buffer buffer
	        (save-excursion
	          (goto-char (lsp-bridge-peek--position-to-point pos))
		      (forward-line content-move)
	          (beginning-of-line 1)
	          (cons (point)
		            (lsp-bridge-peek--search-symbols
		             lsp-bridge-peek-file-content-height)))))
    (setq lsp-bridge-peek--ace-seqs (lsp-bridge-peek--ace-key-seqs
				                     (length (cdr lsp-bridge-peek--symbol-bounds))))
    (lsp-bridge-peek--show 'force)
    (cl-block nil
      (while (setq key (read-key "Ace char:"))
	    (when (memq key lsp-bridge-peek-ace-cancel-keys)
	      (setq lsp-bridge-peek--symbol-bounds nil)
	      (setq lsp-bridge-peek--ace-seqs nil)
	      (lsp-bridge-peek--show 'force)
	      (cl-return))
	    (pcase (lsp-bridge-peek--pop-ace-key-seqs lsp-bridge-peek--ace-seqs key)
	      ((and (pred integerp) i)
	       (let ((pos (car (nth i (cdr lsp-bridge-peek--symbol-bounds)))))
	         (setq lsp-bridge-peek--symbol-bounds nil)
	         (setq lsp-bridge-peek--ace-seqs nil)
	         (lsp-bridge-peek--show 'force)
	         (cl-return (cons file pos))))
	      (_ (lsp-bridge-peek--show 'force)))))))

(defun lsp-bridge-peek-through ()
  "Peek through a symbol in current peek window."
  (interactive)
  (lsp-bridge-peek--error-if-not-peeking)
  (when lsp-bridge-peek--active-request
    (user-error "A previous LSP peek request is still pending"))
  (with-temp-message ""
    (when-let* ((file-pos (lsp-bridge-ace-pick-point-in-peek-window))
                (file (car file-pos))
                (pos (cdr file-pos)))
      (let* ((origin-buffer (current-buffer))
             (origin-marker (point-marker))
             (existing-buffer (find-buffer-visiting file))
             (target-buffer (or existing-buffer (find-file-noselect file)))
             (session-id (lsp-bridge-peek--next-request-id)))
        (with-current-buffer target-buffer
          (save-excursion
            (goto-char (min (max pos (point-min)) (point-max)))
            (let ((target-marker (point-marker)))
              (setq lsp-bridge-peek--active-request
                    (list :id session-id
                          :origin-buffer origin-buffer
                          :origin-marker origin-marker
                          :origin-window (selected-window)
                          :target-buffer target-buffer
                          :target-marker target-marker
                          :temporary-buffer (unless existing-buffer
                                              target-buffer)))
              (lsp-bridge-peek--arm-request-timeout session-id "definition")
              (setq lsp-bridge-peek-chosen-displaying-list (make-list 3 0))
              (setf (nth 2 lsp-bridge-peek-chosen-displaying-list)
                    (1- lsp-bridge-peek-list-height))
              (condition-case err
                  (lsp-bridge-peek session-id)
                (error
                 (lsp-bridge-peek--cleanup-request session-id)
                 (signal (car err) (cdr err)))))))))))

(defun lsp-bridge-peek-tree-previous-node ()
  "Select the previous node in the tree history."
  (interactive)
  (lsp-bridge-peek--error-if-not-peeking)
  (setq lsp-bridge-peek-chosen-displaying-list (make-list 3 0))
  (setf (nth 2 lsp-bridge-peek-chosen-displaying-list) (1- lsp-bridge-peek-list-height))
  (let* ((selected-symbol (nth lsp-bridge-peek-selected-symbol lsp-bridge-peek-symbol-tree))
	     (parent-symbol (nth 3 selected-symbol)))
    (when parent-symbol
	  (setq lsp-bridge-peek-selected-symbol parent-symbol)
	  (setq lsp-bridge-peek--content-update t))))

(defun lsp-bridge-peek-tree-next-node ()
  "Select the next node in the tree history."
  (interactive)
  (lsp-bridge-peek--error-if-not-peeking)
  (setq lsp-bridge-peek-chosen-displaying-list (make-list 3 0))
  (setf (nth 2 lsp-bridge-peek-chosen-displaying-list) (1- lsp-bridge-peek-list-height))
  (let* ((selected-symbol (nth lsp-bridge-peek-selected-symbol lsp-bridge-peek-symbol-tree))
	     (child-list (nth 4 selected-symbol))
	     (selected-child (nth 5 selected-symbol)))
    (when child-list
	  (setq lsp-bridge-peek-selected-symbol (nth selected-child child-list))
	  (setq lsp-bridge-peek--content-update t))))

(defun lsp-bridge-peek-tree-change-branch (num)
  (lsp-bridge-peek--error-if-not-peeking)
  (setq lsp-bridge-peek-chosen-displaying-list (make-list 3 0))
  (setf (nth 2 lsp-bridge-peek-chosen-displaying-list) (1- lsp-bridge-peek-list-height))
  (cl-symbol-macrolet ((selected-symbol
			             (nth lsp-bridge-peek-selected-symbol lsp-bridge-peek-symbol-tree)))
    (if (nth 3 selected-symbol)
	    (cl-symbol-macrolet ((parent-symbol (nth (nth 3 selected-symbol) lsp-bridge-peek-symbol-tree))
			                 (brother-list (nth 4 parent-symbol))
			                 (selected-brother (nth 5 parent-symbol)))
	      (if selected-brother
	          (progn
		        (setq already-changed nil)
		        (unless (or (< (+ num selected-brother) 0)
			                (> (+ num selected-brother) (1- (length brother-list))))
		          (setq selected-brother (+ num selected-brother))
		          (setq already-changed t))
		        (unless already-changed
		          (if (< (+ num selected-brother) 0)
		              (progn
			            (setq selected-brother (1- (length brother-list)))
			            (setq already-changed t))))
		        (unless already-changed
		          (if (> (+ num selected-brother) (1- (length brother-list)))
		              (setq selected-brother 0)))
		        (setq lsp-bridge-peek-selected-symbol (nth selected-brother brother-list))
		        (setq lsp-bridge-peek--content-update t)))))))

(defun lsp-bridge-peek-tree-previous-branch ()
  "Select the previous brach in the tree history."
  (interactive)
  (lsp-bridge-peek-tree-change-branch 1))

(defun lsp-bridge-peek-tree-next-branch ()
  "Select the next brach in the tree history."
  (interactive)
  (lsp-bridge-peek-tree-change-branch -1))


(provide 'lsp-bridge-peek)
;;; lsp-bridge-peek.el ends here.

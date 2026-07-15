;;; lsp-bridge-peek-test.el --- Tests for lsp-bridge peek -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

(load-file
 (expand-file-name "../lsp-bridge-peek.el"
                   (file-name-directory (or load-file-name buffer-file-name))))

(defvar lsp-bridge-tramp-alias-alist nil)

(ert-deftest lsp-bridge-peek-binds-peek-through ()
  (should (eq (lookup-key lsp-bridge-peek-keymap (kbd "t"))
              'lsp-bridge-peek-through)))

(ert-deftest lsp-bridge-peek-ace-supports-multibyte-replacements ()
  (let ((result (lsp-bridge--attach-ace-str
                 (string-make-unibyte "abc")
                 '((1 . 2)) 1 '((?\u4e2d)))))
    (should (multibyte-string-p result))
    (should (= (aref result 0) ?\u4e2d))))

(ert-deftest lsp-bridge-peek-converts-utf16-position ()
  (with-temp-buffer
    (insert "a\U0001f600b")
    (cl-letf (((symbol-function 'acm-backend-lsp-position-to-point)
               (lambda (position)
                 (should (equal position '(:line 0 :character 0)))
                 (point-min))))
      (should (= (lsp-bridge-peek--position-to-point
                  '(:line 0 :character 3))
                 3)))))

(ert-deftest lsp-bridge-peek-position-preserves-shared-line-origin ()
  (with-temp-buffer
    (insert "ignored\ntarget\n")
    (goto-char (point-min))
    (cl-letf (((symbol-function 'acm-backend-lsp-position-to-point)
               (lambda (_position)
                 (line-beginning-position 2))))
      (should (= (lsp-bridge-peek--position-to-point
                  '(:line 0 :character 2))
                 (+ (line-beginning-position 2) 2))))))

(ert-deftest lsp-bridge-peek-file-rendering-preserves-visiting-buffer-point ()
  (let* ((file (make-temp-file "lsp-bridge-peek-render-" nil ".el" "source\n"))
         (buffer (find-file-noselect file))
         (lsp-bridge-peek-chosen-displaying-list '(0 0 0))
         (lsp-bridge-peek-selected-symbol 0)
         (lsp-bridge-peek-symbol-tree
          (list (list 'symbol (list file) (list '(:line 0 :character 0))
                      nil nil nil '(0)))))
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-max))
          (let ((original-point (point)))
            (cl-letf (((symbol-function 'lsp-bridge-peek--get-content)
                       (lambda (_position _move)
                         (goto-char (point-min))
                         "source\n")))
              (lsp-bridge-peek--file-content)
              (should (= (point) original-point)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-file file))))

(ert-deftest lsp-bridge-peek-mode-keeps-request-origin-window ()
  (save-window-excursion
    (let* ((origin-buffer (generate-new-buffer " *peek-window-origin*"))
           (other-buffer (generate-new-buffer " *peek-window-other*"))
           (origin-window (selected-window))
           (other-window (split-window-right)))
      (unwind-protect
          (progn
            (set-window-buffer origin-window origin-buffer)
            (set-window-buffer other-window other-buffer)
            (select-window other-window)
            (with-current-buffer origin-buffer
              (let ((lsp-bridge-peek--active-request
                     (list :id 41 :origin-window origin-window)))
                (lsp-bridge-peek-mode 1)
                (should (eq (overlay-get lsp-bridge-peek--ov 'window)
                            origin-window))
                (lsp-bridge-peek-mode -1))))
        (when (buffer-live-p origin-buffer) (kill-buffer origin-buffer))
        (when (buffer-live-p other-buffer) (kill-buffer other-buffer))))))

(ert-deftest lsp-bridge-peek-prefers-visiting-buffer-content ()
  (let* ((file (make-temp-file "lsp-bridge-peek-visiting-" nil ".el" "disk"))
         (buffer (find-file-noselect file)))
    (unwind-protect
        (with-current-buffer buffer
          (erase-buffer)
          (insert "unsaved")
          (let ((lsp-bridge-peek--buffer-alist nil)
                (lsp-bridge-peek--temp-buffer-alist nil))
            (should (eq (lsp-bridge-peek--find-file-buffer file) buffer))
            (should (equal (buffer-string) "unsaved"))
            (should-not lsp-bridge-peek--temp-buffer-alist)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-file file))))

(ert-deftest lsp-bridge-peek-failure-cleans-request-resources ()
  (let ((origin (generate-new-buffer " *peek-origin*"))
        (target (generate-new-buffer " *peek-target*")))
    (unwind-protect
        (let ((lsp-bridge-peek--active-request
               (list :id 7
                     :origin-buffer origin
                     :origin-marker (with-current-buffer origin (point-marker))
                     :target-buffer target
                     :target-marker (with-current-buffer target (point-marker))
                     :temporary-buffer target))
              (lsp-bridge-peek-symbol-at-point '(symbol)))
          (lsp-bridge-peek--request-failed nil 7 "definition")
          (should-not lsp-bridge-peek--active-request)
          (should-not lsp-bridge-peek-symbol-at-point)
          (should-not (buffer-live-p target)))
      (when (buffer-live-p origin) (kill-buffer origin))
      (when (buffer-live-p target) (kill-buffer target)))))

(ert-deftest lsp-bridge-peek-through-keeps-point-and-sends-session-id ()
  (let* ((file (make-temp-file "lsp-bridge-peek-" nil ".el" "symbol source\n"))
         (buffer (find-file-noselect file))
         request-args)
    (unwind-protect
        (with-current-buffer buffer
          (goto-char 8)
          (let ((lsp-bridge-peek-mode t)
                (lsp-bridge-peek--active-request nil))
            (cl-letf (((symbol-function 'lsp-bridge-ace-pick-point-in-peek-window)
                       (lambda () (cons file 1)))
                      ((symbol-function 'lsp-bridge--position)
                       (lambda () '(:line 0 :character 0)))
                      ((symbol-function 'lsp-bridge-call-file-api)
                       (lambda (&rest args)
                         (setq request-args args)
                         t)))
              (lsp-bridge-peek-through)
              (should (= (point) 8))
              (should (equal (car request-args) "peek_find_definition"))
              (should (integerp (car (last request-args))))
              (lsp-bridge-peek--cleanup-request))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-file file))))

(ert-deftest lsp-bridge-peek-ignores-stale-definition-response ()
  (let ((lsp-bridge-peek--active-request (list :id 10))
        (lsp-bridge-peek-symbol-at-point (make-list 7 nil)))
    (lsp-bridge-peek-define--return "/tmp/stale.el" nil
                                    '(:line 0 :character 0) 9)
    (should-not (nth 1 lsp-bridge-peek-symbol-at-point))))

(ert-deftest lsp-bridge-peek-success-updates-tree-without-moving-point ()
  (let* ((file (make-temp-file "lsp-bridge-peek-success-" nil ".el"
                               "symbol source\n"))
         (buffer (find-file-noselect file))
         (session-id 11)
         references-request)
    (unwind-protect
        (with-current-buffer buffer
          (goto-char 8)
          (let ((lsp-bridge-peek-mode t)
                (lsp-bridge-peek-symbol-tree nil)
                (lsp-bridge-peek-selected-symbol nil)
                (lsp-bridge-peek-symbol-at-point (make-list 7 nil))
                (lsp-bridge-peek--active-request
                 (list :id session-id
                       :origin-buffer buffer
                       :origin-marker (copy-marker (point))
                       :target-buffer buffer
                       :target-marker (copy-marker 1))))
            (setf (nth 0 lsp-bridge-peek-symbol-at-point) 'symbol)
            (cl-letf (((symbol-function 'lsp-bridge--position)
                       (lambda () '(:line 0 :character 0)))
                      ((symbol-function 'lsp-bridge-call-file-api)
                       (lambda (&rest args)
                         (setq references-request args)
                         t))
                      ((symbol-function 'lsp-bridge-peek--show) #'ignore))
              (lsp-bridge-peek-define--return
               file nil '(:line 0 :character 0) session-id)
              (should (equal (car references-request) "peek_find_references"))
              (lsp-bridge-peek-references--return "" 0 session-id)
              (should (= (point) 8))
              (should (= (length lsp-bridge-peek-symbol-tree) 1))
              (should-not lsp-bridge-peek--active-request))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-file file))))

(provide 'lsp-bridge-peek-test)
;;; lsp-bridge-peek-test.el ends here
